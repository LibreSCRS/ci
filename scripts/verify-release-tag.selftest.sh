#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC1007,SC2010,SC2012,SC2015,SC2016,SC2028,SC2181  # fixture text is literal on purpose; A && B || C report lines
# Self-test for verify-release-tag.sh, offline.
#
# The release key is modelled, not borrowed: a certify-only primary with a
# signing SUBKEY, generated here, exactly the shape of the real one -- so the
# field-order trap (VALIDSIG's first field is the subkey) is live in every case.
# The fixture remote is a local repository, so the rehearsal mode runs its
# whole path without the network.
#
# Four cases are perturbations of the SCRIPT, not of the input: each loosens
# one clause of the judgement in a copy and asserts that some fixture then
# goes through. A fixture that the loosened verifier still rejects would be
# testing nothing, so each perturbation is also asserted to have changed the
# file.
set -u
# The caller's git configuration must not reach the fixtures (a global
# tag.gpgSign turns the lightweight fixture into a signed one).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/verify-release-tag.sh"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }
command -v gpg >/dev/null 2>&1 || { echo "gpg is not on PATH -- cannot run" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/var/tmp}/verify-release-tag-selftest.XXXXXX")" || exit 2
cleanup() {
    for k in rel forger; do GNUPGHOME="$work/$k" gpgconf --kill all >/dev/null 2>&1 || true; done
    rm -rf "$work"
}
trap cleanup EXIT

cases=0; red=0; fails=0
check() {  # check <name> <want-rc> <needle|-> -- <command...>
    local name=$1 want=$2 needle=$3 out got
    shift 4
    cases=$((cases + 1))
    [ "$want" != 0 ] && red=$((red + 1))
    out="$("$@" 2>&1)"; got=$?
    if [ "$got" != "$want" ]; then
        printf 'FAIL  %s: rc=%s, want %s\n' "$name" "$got" "$want"
        printf '%s\n' "$out" | sed 's/^/  | /'
        fails=$((fails + 1)); return
    fi
    if [ "$needle" != - ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
        printf 'FAIL  %s: rc=%s as wanted, but the output does not say "%s"\n' "$name" "$got" "$needle"
        printf '%s\n' "$out" | sed 's/^/  | /'
        fails=$((fails + 1)); return
    fi
    printf 'ok    %s (rc=%s)\n' "$name" "$got"
}

# ------------------------------------------------------------------ keys --
mkdir -m 700 "$work/rel" "$work/forger"
G() { GNUPGHOME="$work/$1" gpg --batch --quiet --pinentry-mode loopback --passphrase '' "${@:2}"; }
G rel --quick-gen-key "Selftest Release <release@invalid>" ed25519 cert 1d >/dev/null 2>&1 || exit 2
pfpr="$(G rel --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')"
G rel --quick-add-key "$pfpr" ed25519 sign 1d >/dev/null 2>&1 || exit 2
sfpr="$(G rel --with-colons --list-keys | awk -F: '$1=="fpr"{n++} $1=="fpr" && n==2 {print $10; exit}')"
G forger --quick-gen-key "Selftest Forger <forger@invalid>" ed25519 sign 1d >/dev/null 2>&1 || exit 2
ffpr="$(G forger --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')"
[ -n "$pfpr" ] && [ -n "$sfpr" ] && [ -n "$ffpr" ] && [ "$pfpr" != "$sfpr" ] \
    || { echo "could not model the release key" >&2; exit 2; }
G rel --armor --export "$pfpr" > "$work/KEYS"
{ cat "$work/KEYS"; G forger --armor --export "$ffpr"; } > "$work/KEYS.both"

# ---------------------------------------------------------------- remote --
r="$work/remote"
git init -q "$r"
gr() { GNUPGHOME="$work/$1" git -C "$r" -c user.name=t -c user.email=t@invalid \
        -c commit.gpgSign=false -c gpg.format=openpgp "${@:2}"; }
cp "$work/KEYS" "$r/KEYS"
gr rel add KEYS && gr rel commit -q -m fixture
gr rel -c user.signingKey="$pfpr" tag -s -m "release 4.2.0" 4.2.0 >/dev/null 2>&1 || exit 2
gr rel -c user.signingKey="$pfpr" tag -s -m "release 5.0.0" 5.0.0 >/dev/null 2>&1 || exit 2
gr forger -c user.signingKey="$ffpr" tag -s -m "forged 5.0.9" 5.0.9 >/dev/null 2>&1 || exit 2
gr rel -c tag.gpgSign=false tag -a -m "unsigned 5.0.1" 5.0.1
gr rel -c tag.gpgSign=false tag 5.0.2
git -C "$r" update-ref refs/tags/9.9.9 "$(git -C "$r" rev-parse refs/tags/4.2.0)"
# The signing really happened with the SUBKEY -- otherwise P1 below proves
# nothing about field order.
GNUPGHOME="$work/rel" git -C "$r" verify-tag --raw 4.2.0 2>&1 | grep -q "VALIDSIG $sfpr .* $pfpr\$" \
    || { echo "the fixture tag was not signed by the subkey" >&2; exit 2; }

env0=(env -u GITHUB_WORKSPACE -u KEYS_FILE REPO_ROOT="$r" EXPECTED_FPR="$pfpr"
      FIXTURE_REMOTE="$r" FIXTURE_TAG=4.2.0)
vt() { "${env0[@]}" bash "${VT:-$subject}" "$@"; }

# --------------------------------------------------------------- tag mode --
check "T1 a tag signed by the release key's subkey" 0 "signed by the LibreSCRS release key" -- vt tag 4.2.0
check "T2 an unsigned annotated tag" 1 "not signed" -- vt tag 5.0.1
check "T3 a lightweight tag" 1 "not an annotated tag object (commit)" -- vt tag 5.0.2
check "T4 a tag by another key that KEYS also carries" 1 "not signed" -- \
    env -u GITHUB_WORKSPACE KEYS_FILE="$work/KEYS.both" REPO_ROOT="$r" \
    EXPECTED_FPR="$pfpr" bash "$subject" tag 5.0.9
check "T5 the 4.2.0 object pushed under another name" 1 "calls itself '4.2.0'" -- vt tag 9.9.9
check "T6 a tag that does not exist" 1 "absent" -- vt tag 7.7.7
check "T7 no KEYS file" 2 "no KEYS" -- env KEYS_FILE="$work/nowhere" REPO_ROOT="$r" \
    EXPECTED_FPR="$pfpr" bash "$subject" tag 4.2.0
check "T8 KEYS without the pinned key" 1 "fingerprint mismatch" -- \
    env -u KEYS_FILE REPO_ROOT="$r" EXPECTED_FPR=0123456789ABCDEF0123456789ABCDEF01234567 \
    bash "$subject" tag 4.2.0
check "T9 the SUBKEY pinned in place of the primary" 1 "as a primary key" -- \
    env -u KEYS_FILE REPO_ROOT="$r" EXPECTED_FPR="$sfpr" bash "$subject" tag 4.2.0
check "T10 a fingerprint that is not 40 upper-case hex" 2 "40-hex" -- \
    env REPO_ROOT="$r" EXPECTED_FPR="${pfpr,,}" bash "$subject" tag 4.2.0
check "T11 no tag name is a usage error" 2 "usage" -- vt tag ""

# The consumer's tree is REPO_ROOT, even from a foreign cwd and with a
# workspace variable pointing somewhere else.
mkdir -p "$work/decoy"
check "C1 REPO_ROOT wins over a decoy workspace, from /" 0 - -- \
    env GITHUB_WORKSPACE="$work/decoy" REPO_ROOT="$r" EXPECTED_FPR="$pfpr" \
    bash -c 'cd / && bash "$1" tag 4.2.0' _ "$subject"

# ---------------------------------------------------------- rehearse mode --
check "R1 the rehearsal over a signed fixture" 0 "1 accepted, 5 rejected" -- vt rehearse
check "R2 the rehearsal when the fixture tag is unsigned" 1 "must be ACCEPTED" -- \
    env -u GITHUB_WORKSPACE -u KEYS_FILE REPO_ROOT="$r" EXPECTED_FPR="$pfpr" \
    FIXTURE_REMOTE="$r" FIXTURE_TAG=5.0.1 bash "$subject" rehearse
check "R3 the rehearsal when the fixture cannot be fetched" 2 "could not be fetched" -- \
    env FIXTURE_REMOTE="$work/no-such-remote" REPO_ROOT="$r" EXPECTED_FPR="$pfpr" bash "$subject" rehearse
check "R4 rehearse takes no argument" 2 "usage" -- vt rehearse extra

# ------------------------------------------- perturbations of the verifier --
perturb() {  # perturb <id> <old> <new> [<old> <new>...]: a copy, each literal clause replaced
    local id=$1 p="$work/$1.sh"
    shift
    # Every clause must be found: a replacement that matched nothing leaves a
    # "perturbed" verifier identical in that respect, and its red proves nothing.
    python3 - "$subject" "$p" "$@" <<'PY' || { echo "FAIL  $id: a clause to perturb is not in the verifier"; fails=$((fails + 1)); }
import sys
src, dst, *pairs = sys.argv[1:]
text = open(src).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    if old not in text:
        sys.exit(1)
    text = text.replace(old, new)
open(dst, "w").write(text)
PY
    PERTURBED="$p"
}
pin='VALIDSIG [0-9A-F]{40} .* ${EXPECTED_FPR}\$'
# P1 -- the primary matched in the FIRST field, the bug the field-order note
# describes: every genuinely signed tag is rejected.
perturb P1 "$pin" 'VALIDSIG ${EXPECTED_FPR} '
VT="$PERTURBED" check "P1 primary matched in the first field rejects the real tag" 1 "not signed" -- vt tag 4.2.0
# P2 -- a bare fingerprint grep that also ignores gpg's exit status:
# KEY_CONSIDERED carries the primary even for a BADSIG, so the altered-content
# fixture goes through. (Either clause alone still refuses it, which is why
# the verifier keeps both.)
perturb P2 "grep -qE \"^\\[GNUPG:\\] $pin\"" 'grep -q "${EXPECTED_FPR}"' \
    'if [ "$vrc" -eq 0 ] \' 'if true \'
VT="$PERTURBED" check "P2 a bare fingerprint grep is caught by the BADSIG fixture" 1 "(BADSIG) was ACCEPTED" -- vt rehearse
# P3 -- no object-name check: the replayed object goes through.
perturb P3 'if [ "$name" != "$want" ]; then' 'if false; then'
VT="$PERTURBED" check "P3 no object-name check is caught by the replay fixture" 1 "another name was ACCEPTED" -- vt rehearse
# P4 -- VALIDSIG by anyone: the forger, once known to the keyring, goes through.
perturb P4 "$pin" 'VALIDSIG '
VT="$PERTURBED" check "P4 an unpinned VALIDSIG is caught by the known-forger fixture" 1 "knows that key was ACCEPTED" -- vt rehearse

if [ "$fails" -eq 0 ]; then
    echo "verify-release-tag selftest: all cases passed"
else
    echo "verify-release-tag selftest: $fails case(s) failed"
fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fails" -eq 0 ]
