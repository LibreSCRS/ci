#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Self-test for check-cleansing-deleters: prove the gate can fail, one clause at
# a time, in both modes, and that it never reads "cannot judge" as clean.
#
# A minimal green tree is committed to a throwaway git repository (the gate
# reads git ls-files and refuses to run outside a work tree, so an uncommitted
# tree would make every case exit 2, and a case asserting only "not 0" would
# pass having measured nothing). Each perturbation is checked to have changed
# its file before the gate runs, and the file is put back from a copy.
#
#   C0  green canonical tree                                      -> 0
#   C1  BnDeleter body back to plain BN_free                      -> 1 (clause 1)
#   C2  the word PACE gone from the comment above it              -> 1 (clause 2)
#   C3  a struct deleter elsewhere back to plain BN_free          -> 1 (clause 3)
#   C4  a struct deleter with a spaced pointer star               -> 1 (clause 3)
#   C5  a function-pointer deleter back to plain BN_free          -> 1 (clause 4)
#   C6  a lambda deleter back to plain BN_free                    -> 1 (clause 4)
#   C7  bare BN_free on public values outside any deleter         -> 0 (not too wide)
#   C8  a plain BN_free deleter in an UNTRACKED file              -> 0 (git ls-files only)
#   E1  the excused site, left alone                              -> 0
#   E2  without its exception line the same site                  -> 1
#   E3  an exception matching nothing any more                    -> 1 (stale amnesty)
#   E4  an exception naming an untracked path                     -> 1
#   E5  a second plain deleter in the excused file                -> 1 (site, not file)
#   E6  an exception naming a path and no line                    -> 1
#   E7  an excused struct deleter (clause 3 is never excused)     -> 1
#   M0  green mirror tree                                         -> 0
#   M1  the mirror's body back to plain BN_free                   -> 1 (clause 1)
#   M2  the MIRROR-OF marker gone                                 -> 1 (clause 2)
#   M3  the marker names another canonical                        -> 1 (clause 2)
#   M4  a mirror read with the canonical's rule (no PACE there)   -> 1
#   X1  no 'struct BnDeleter' in the file                         -> 2
#   X2  outside any git work tree                                 -> 2
#   X3  no mode, both modes, --mirror without its name            -> 2
#   X4  an exceptions file that is not there                      -> 2
#   X5  the file named is not there                               -> 2
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$here/check-cleansing-deleters"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/cleansing-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

cases=0; red=0; fail=0
check() {  # check <label> <want-rc> <got-rc> <out> [needle]
    cases=$((cases + 1))
    [ "$3" != 0 ] && [ "$2" = "$3" ] && red=$((red + 1))
    if [ "$2" != "$3" ]; then
        echo "FAIL $1: want rc=$2, got rc=$3"; printf '%s\n' "$4" | sed 's/^/  | /'; fail=1; return
    fi
    if [ -n "${5:-}" ]; then
        case "$4" in
            *"$5"*) ;;
            *) echo "FAIL $1: rc=$3 as wanted, but the output does not say '$5'"
               printf '%s\n' "$4" | sed 's/^/  | /'; fail=1; return ;;
        esac
    fi
    echo "ok   $1 (rc=$3)"
}
commit() { git -C "$1" add -A && git -C "$1" -c commit.gpgsign=false commit -qm x; }
newrepo() {
    mkdir -p "$1"; git -C "$1" init -q; git -C "$1" config user.email t@t; git -C "$1" config user.name t
}
perturb() {  # perturb <label> <file> <sed-expr>: false (and a FAIL) when nothing changed
    cp "$2" "$WORK/pre.tmp"
    sed -e "$3" "$WORK/pre.tmp" > "$2"
    if cmp -s "$WORK/pre.tmp" "$2"; then
        echo "FAIL $1: the perturbation changed nothing in $2"; fail=1; return 1
    fi
}

# ── the canonical tree ───────────────────────────────────────────────────
C="$WORK/canonical"; newrepo "$C"
HDR=include/Crypto/OpenSslPtr.h
SHAPES=src/shapes.cpp
PUBLIC=src/public.cpp
PROBE=test/probe.cpp
EXC=ci/cleansing-deleter-exceptions.txt
mkdir -p "$C/include/Crypto" "$C/src" "$C/test" "$C/ci"
cat > "$C/$HDR" <<'EOF'
#pragma once
#include <memory>
#include <openssl/bn.h>
/// Frees a BIGNUM, zeroing its limb buffer first.
///
/// PACE holds secrets that exist only as a BIGNUM, and nothing else wipes them.
struct BnDeleter
{
    void operator()(BIGNUM* p) const noexcept
    {
        BN_clear_free(p);
    }
};
EOF
cat > "$C/$SHAPES" <<'EOF'
#include <memory>
#include <openssl/bn.h>
struct FixtureDeleter
{
    void operator()(BIGNUM* p) const
    {
        BN_clear_free(p);
    }
};
std::unique_ptr<BIGNUM, decltype(&BN_clear_free)> adopt(BIGNUM* p)
{
    return {p, &BN_clear_free};
}
auto releaseBignum = [](BIGNUM* q) { BN_clear_free(q); };
struct SpacedDeleter
{
    void operator()(BIGNUM *s) const
    {
        BN_clear_free(s);
    }
};
EOF
cat > "$C/$PUBLIC" <<'EOF'
#include <openssl/bn.h>
int encode(BIGNUM* r, BIGNUM* s)
{
    if (r == nullptr) {
        BN_free(s);
        return -1;
    }
    BN_free(r);
    BN_free(s);
    return 0;
}
EOF
cat > "$C/$PROBE" <<'EOF'
#include <openssl/bn.h>
int control()
{
    return measure([](BIGNUM* p) { BN_free(p); });
}
EOF
printf '# one path:line per entry, then the reason\n%s:4  the control leg must call plain BN_free\n' "$PROBE" > "$C/$EXC"
commit "$C"
for f in "$HDR" "$SHAPES" "$PROBE" "$EXC"; do cp "$C/$f" "$WORK/$(basename "$f").bak"; done
restore() { for f in "$HDR" "$SHAPES" "$PROBE" "$EXC"; do cp "$WORK/$(basename "$f").bak" "$C/$f"; done; }
canon() { bash "$CHECK" --root "$C" --canonical "$HDR" --exceptions "$EXC" "$@" 2>&1; }

out="$(canon)"; check "C0 green canonical tree" 0 $? "$out" "check-cleansing-deleters: OK"
if perturb C1 "$C/$HDR" 's/BN_clear_free(p);/BN_free(p);/'; then
    out="$(canon)"; check "C1 the canonical body back to plain BN_free" 1 $? "$out" "BnDeleter does not call BN_clear_free"
fi; restore
if perturb C2 "$C/$HDR" 's/PACE/It/'; then
    out="$(canon)"; check "C2 the reason gone, the call kept" 1 $? "$out" "does not mention PACE"
fi; restore
if perturb C3 "$C/$SHAPES" 's/BN_clear_free(p);/BN_free(p);/'; then
    out="$(canon)"; check "C3 a struct deleter elsewhere back to plain BN_free" 1 $? "$out" "$SHAPES-7-"
fi; restore
if perturb C4 "$C/$SHAPES" 's/BN_clear_free(s);/BN_free(s);/'; then
    out="$(canon)"; check "C4 a struct deleter with a spaced star" 1 $? "$out" "a BIGNUM deleter calls plain BN_free"
fi; restore
if perturb C5 "$C/$SHAPES" 's/decltype(&BN_clear_free)/decltype(\&BN_free)/'; then
    out="$(canon)"; check "C5 a function-pointer deleter back to plain BN_free" 1 $? "$out" "$SHAPES:10:"
fi; restore
if perturb C6 "$C/$SHAPES" 's/BN_clear_free(q);/BN_free(q);/'; then
    out="$(canon)"; check "C6 a lambda deleter back to plain BN_free" 1 $? "$out" "released through a plain BN_free deleter"
fi; restore
out="$(canon)"; rc=$?
case "$out" in *"$PUBLIC"*) rc=9 ;; esac
check "C7 bare BN_free on public values is not this gate's (and is not named)" 0 "$rc" "$out"
printf 'struct Loose\n{\n    void operator()(BIGNUM* p) const\n    {\n        BN_free(p);\n    }\n};\n' > "$C/src/untracked.cpp"
out="$(canon)"; check "C8 an untracked file is not measured" 0 $? "$out"
rm -f "$C/src/untracked.cpp"

out="$(canon)"; rc=$?
case "$out" in *"$PROBE"*) rc=9 ;; esac
check "E1 the excused site is not reported" 0 "$rc" "$out"
if perturb E2 "$C/$EXC" "s@^$PROBE@#&@"; then
    out="$(canon)"; check "E2 the same site without its exception" 1 $? "$out" "$PROBE:4:"
fi; restore
printf '%s:99  nothing there releases a BIGNUM\n' "$SHAPES" >> "$C/$EXC"
out="$(canon)"; check "E3 a stale exception" 1 $? "$out" "no longer releases a BIGNUM"; restore
printf 'test/gone.cpp:5  deleted three releases ago\n' >> "$C/$EXC"
out="$(canon)"; check "E4 an exception naming an untracked path" 1 $? "$out" "is not a tracked file"; restore
printf 'auto second = [](BIGNUM* p) { BN_free(p); };\n' >> "$C/$PROBE"; commit "$C"
out="$(canon)"; check "E5 a second plain deleter in the excused file" 1 $? "$out" "$PROBE:6:"
restore; commit "$C"
printf '%s  an amnesty with no line in it\n' "$PROBE" >> "$C/$EXC"
out="$(canon)"; check "E6 an exception naming no line" 1 $? "$out" "which names no line"; restore
if perturb E7 "$C/$SHAPES" 's/BN_clear_free(p);/BN_free(p);/'; then
    printf '%s:7  a struct deleter cannot be excused\n' "$SHAPES" >> "$C/$EXC"
    out="$(canon)"; check "E7 an excused struct deleter is still red" 1 $? "$out" "a BIGNUM deleter calls plain BN_free"
fi; restore

# ── the mirror tree ──────────────────────────────────────────────────────
M="$WORK/mirror"; newrepo "$M"
MIR=tests/Fixture.cpp
mkdir -p "$M/tests"
cat > "$M/$MIR" <<'EOF'
#include <memory>
#include <openssl/bn.h>
// MIRROR-OF: Middleware/include/Crypto/OpenSslPtr.h - the canonical header is
// internal to another repository and unreachable from here.
struct BnDeleter
{
    void operator()(BIGNUM* p) const noexcept
    {
        BN_clear_free(p);
    }
};
EOF
commit "$M"; cp "$M/$MIR" "$WORK/mirror.bak"
mirror() { bash "$CHECK" --root "$M" --mirror "$MIR" --canonical-name "${1:-OpenSslPtr.h}" 2>&1; }
out="$(mirror)"; check "M0 green mirror tree" 0 $? "$out" "names OpenSslPtr.h"
if perturb M1 "$M/$MIR" 's/BN_clear_free(p);/BN_free(p);/'; then
    out="$(mirror)"; check "M1 the mirror's body back to plain BN_free" 1 $? "$out" "BnDeleter does not call BN_clear_free"
fi; cp "$WORK/mirror.bak" "$M/$MIR"
if perturb M2 "$M/$MIR" 's/MIRROR-OF: //'; then
    out="$(mirror)"; check "M2 the marker gone" 1 $? "$out" "no longer says MIRROR-OF"
fi; cp "$WORK/mirror.bak" "$M/$MIR"
out="$(mirror OpenSslPtrCms.h)"; check "M3 the marker names another canonical" 1 $? "$out" "no longer says MIRROR-OF"
out="$(bash "$CHECK" --root "$M" --canonical "$MIR" 2>&1)"; check "M4 a mirror judged by the canonical's rule" 1 $? "$out" "does not mention PACE"

# ── cannot judge ─────────────────────────────────────────────────────────
if perturb X1 "$C/$HDR" 's/^struct BnDeleter$/struct BnRelease/'; then
    out="$(canon)"; check "X1 no struct BnDeleter to judge" 2 $? "$out" "no 'struct BnDeleter'"
fi; restore
N="$WORK/nogit"; mkdir -p "$N/include/Crypto"; cp "$WORK/OpenSslPtr.h.bak" "$N/$HDR"
if git -C "$N" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "FAIL X2: $N sits inside a git work tree, so the case cannot measure"; fail=1
else
    out="$(bash "$CHECK" --root "$N" --canonical "$HDR" 2>&1)"; check "X2 outside a git work tree" 2 $? "$out" "not a git work tree"
fi
out="$(bash "$CHECK" --root "$C" 2>&1)"; check "X3a no mode" 2 $? "$out" "--canonical or --mirror"
out="$(bash "$CHECK" --root "$C" --canonical "$HDR" --mirror "$HDR" --canonical-name x 2>&1)"; check "X3b both modes" 2 $? "$out" "exclusive"
out="$(bash "$CHECK" --root "$M" --mirror "$MIR" 2>&1)"; check "X3c --mirror without its name" 2 $? "$out" "--mirror needs --canonical-name"
out="$(canon --bogus 2>&1)"; check "X3d an unknown argument" 2 $? "$out" "unknown argument"
out="$(bash "$CHECK" --root "$C" --canonical "$HDR" --exceptions ci/none.txt 2>&1)"; check "X4 an exceptions file that is not there" 2 $? "$out" "is not there"
out="$(bash "$CHECK" --root "$C" --canonical include/gone.h 2>&1)"; check "X5 the file named is not there" 2 $? "$out" "not found"

if [ "$fail" -eq 0 ]; then echo "check-cleansing-deleters selftest: all cases passed"; else echo "check-cleansing-deleters selftest: FAILED"; fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fail" -eq 0 ]
