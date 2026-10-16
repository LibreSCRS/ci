#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (rpm signing runs in the distributions' own images)
# Self-test for pkg-sign.sh / pkg-sign-inside.sh against real containers of
# fedora43 (rpm 6) and opensusetw (rpm 4.20): a noarch rpm built in each, the
# public rehearsal key, and a second key B made here. Red cases: the wrong
# named signer, an rpm slipped in unsigned after signing, a revoked signing
# subkey (in both images), a package signed by a key the certificate does not
# hold, and a publish without its key. A control case shows why `rpm -K` is
# never the judge: it exits 0 for an unsigned package.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ci="$(cd -- "$here/.." && pwd)"
tool="$here/pkg-sign.sh"
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker is not on PATH -- cannot measure" >&2; exit 2; }
F43="$("$here/pkg-images" get fedora43)" || exit 2
TW="$("$here/pkg-images" get opensusetw)" || exit 2
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-sign-dt.XXXXXX")" || exit 2
tag="pkst-$$"
cleanup() {
    docker ps -aq --filter "name=^$tag-" | xargs -r docker rm -f >/dev/null 2>&1
    rm -rf "$work" 2>/dev/null \
        || { timeout -k 10 120 docker run --rm -v "$work:/w" "$F43" find /w -mindepth 1 -delete >/dev/null 2>&1; rm -rf "$work"; }
}
trap cleanup EXIT
own="$(id -u):$(id -g)"
n=0
run() { n=$((n + 1)); docker run --rm --name "$tag-$n" "$@"; }

cases=0; red=0; fail=0
expect() {   # expect NAME WANT GOT  -- a red case counts only when the gate said 1
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; tail -n 15 "$work/log" | sed 's/^/  | /'; fail=1; fi
}
control() {  # a measurement, not a gate: never counted as red-proved
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (control, rc=$3)"
    else echo "FAIL $1: want rc=$2, got rc=$3"; tail -n 15 "$work/log" | sed 's/^/  | /'; fail=1; fi
}

# shellcheck disable=SC1091
. "$ci/keys/rehearsal.env" || exit 2
fx="$work/fx"; mkdir -p "$fx"
command cp -f "$ci/keys/rehearsal.asc" "$fx/rehearsal.asc"

# --- fixture --------------------------------------------------------------
cat >"$work/fixture.sh" <<'EOF'
set -euo pipefail
case "$PKG_MANAGER" in
    dnf)    dnf -y -q install rpm-build sequoia-sq >/dev/null ;;
    zypper) zypper -n -q install rpm-build >/dev/null ;;
esac
mkdir -p /w/rb/SPECS
cat >/w/rb/SPECS/x.spec <<'SPEC'
Name: x
Version: 1.0
Release: 1
Summary: pkg-sign fixture
License: MIT
BuildArch: noarch
%description
pkg-sign fixture.
%files
SPEC
rpmbuild --define "_topdir /w/rb" -bb /w/rb/SPECS/x.spec >/dev/null 2>&1
command cp -f /w/rb/RPMS/noarch/x-1.0-1.noarch.rpm "/w/fx/x-1.0-1.noarch.$SLUG.rpm"
rm -rf /w/rb
if [ "$PKG_MANAGER" = dnf ]; then
    export SEQUOIA_HOME GNUPGHOME
    SEQUOIA_HOME="$(mktemp -d /var/tmp/sq.XXXXXX)"; GNUPGHOME="$(mktemp -d /var/tmp/lg.XXXXXX)"
    t="$(mktemp -d /var/tmp/t.XXXXXX)"
    # key B: a signing key the rehearsal certificate does not hold
    sq key generate --own-key --userid 'pkg-sign test key B <b@invalid>' --expiration never \
        --can-sign --cannot-authenticate --cannot-encrypt --without-password \
        --output /w/fx/b.sec.asc --rev-cert "$t/b.rev" 2>/dev/null
    pb="$(sq inspect /w/fx/b.sec.asc | awk '/Fingerprint:/{print $2}' | head -n 1)"
    sq inspect /w/fx/b.sec.asc | awk '/Subkey:/{print $2}' >/w/fx/b.signer
    sq cert import /w/fx/b.sec.asc 2>/dev/null
    sq cert export --cert "$pb" --output /w/fx/b.asc
    # the rehearsal certificate with S_RPM revoked
    sq key subkey revoke --cert-file /k/rehearsal.sec.asc --key "$S_RPM_FPR" \
        --reason compromised --message 'pkg-sign test revocation' --output "$t/rev.asc" 2>/dev/null
    SEQUOIA_HOME="$(mktemp -d /var/tmp/sq.XXXXXX)"
    sq cert import /k/rehearsal.asc 2>/dev/null
    sq cert import "$t/rev.asc" 2>/dev/null
    sq cert export --cert "$PACKAGE_FPR" --output /w/fx/revoked.asc
    sq inspect /w/fx/revoked.asc >/w/fx/revoked.txt
fi
chown -R "$OWN" /w
EOF
echo "-- fixture (fedora43, opensusetw)"
run -e OWN="$own" -e SLUG=fedora43 -e PKG_MANAGER=dnf -e "S_RPM_FPR=$S_RPM_FPR" -e "PACKAGE_FPR=$PACKAGE_FPR" \
    -v "$work:/w" -v "$work/fixture.sh:/fixture.sh:ro" -v "$ci/keys:/k:ro" "$F43" bash /fixture.sh >"$work/log" 2>&1 \
    || { echo "FATAL: the fedora43 fixture did not build -- cannot measure"; cat "$work/log"; exit 2; }
run -e OWN="$own" -e SLUG=opensusetw -e PKG_MANAGER=zypper \
    -v "$work:/w" -v "$work/fixture.sh:/fixture.sh:ro" "$TW" bash /fixture.sh >"$work/log" 2>&1 \
    || { echo "FATAL: the opensusetw fixture did not build -- cannot measure"; cat "$work/log"; exit 2; }
for f in x-1.0-1.noarch.fedora43.rpm x-1.0-1.noarch.opensusetw.rpm b.asc b.sec.asc b.signer revoked.asc; do
    [ -s "$fx/$f" ] || { echo "FATAL: fixture $f is missing -- cannot measure"; exit 2; }
done
B_SIGNER="$(head -n 1 "$fx/b.signer")"
# the revoked certificate must really say so, or case 4 proves nothing
grep -A6 "Subkey: $S_RPM_FPR" "$fx/revoked.txt" | grep -qi 'revoked' \
    || { echo "FATAL: the revoked certificate does not show S_RPM revoked -- cannot measure"; cat "$fx/revoked.txt"; exit 2; }
printf 'not a package\n' >"$fx/y_1-1.deb13_all.debian13.deb"

fresh() {  # fresh DIR FILE... -- a package directory holding copies
    local d="$1"; shift; mkdir -p "$d"
    for f in "$@"; do command cp -f "$fx/$f" "$d/"; done
}
inside() {  # inside IMAGE MANAGER DIR CERT SIGNER [SIGN_KEY] -- MODE from env
    local key=() rc
    [ -z "${6:-}" ] || key=(-e "SIGN_KEY=/k/$6")
    run -v "$3:/p" -v "$fx:/k:ro" -v "$here:/ci-scripts:ro" -e MODE -e "PKG_MANAGER=$2" \
        -e "CERT=/k/$4" -e "SIGNER=$5" "${key[@]}" "$1" bash /ci-scripts/pkg-sign-inside.sh
    rc=$?
    run -v "$3:/p" "$1" chown -R "$own" /p >/dev/null 2>&1
    return "$rc"
}
both=(x-1.0-1.noarch.fedora43.rpm x-1.0-1.noarch.opensusetw.rpm)

# 1. sign with the rehearsal key set; both verify; the .deb is untouched
d1="$work/d1"; fresh "$d1" "${both[@]}" y_1-1.deb13_all.debian13.deb
"$tool" --dir "$d1" --keyset rehearsal >"$work/log" 2>&1; rc=$?
ok=0
for f in "${both[@]}"; do
    cmp -s "$fx/$f" "$d1/$f" && ok=1                     # unchanged = not signed
    [ "$(stat -c %u:%g "$d1/$f")" = "$own" ] || ok=1     # handed back to us
    grep -q "^verified  $f  ($S_RPM_FPR)" "$work/log" || ok=1
done
expect "1a. rehearsal key set signs both images' rpms, each verified by name" "0 0" "$rc $ok"
"$tool" --dir "$d1" --keyset rehearsal --verify-only >"$work/log" 2>&1; rc=$?
n_ver="$(grep -c '^verified  ' "$work/log")"
expect "1b. --verify-only accepts both signed rpms" "0 2" "$rc $n_ver"
for img in F43:fedora43 TW:opensusetw; do   # what the signer check reads, for the log
    IFS=: read -r iv slug <<<"$img"
    run -v "$d1:/p:ro" "${!iv}" rpm -qp --qf 'DSAHEADER=%{DSAHEADER:pgpsig} | SIGPGP=%{SIGPGP:pgpsig}\n' \
        "/p/x-1.0-1.noarch.$slug.rpm" 2>&1 | sed "s/^/     ($slug) /"
done
cmp -s "$fx/y_1-1.deb13_all.debian13.deb" "$d1/y_1-1.deb13_all.debian13.deb"
expect "1c. the .deb is byte-identical" 0 $?

# 2. the signer is named: S_RPM's signature is not S_IDX's
for img in F43:dnf:fedora43 TW:zypper:opensusetw; do
    IFS=: read -r iv mgr slug <<<"$img"
    d="$work/d2-$slug"; mkdir -p "$d"; command cp -f "$d1/x-1.0-1.noarch.$slug.rpm" "$d/"
    MODE=verify inside "${!iv}" "$mgr" "$d" rehearsal.asc "$S_IDX_FPR" >"$work/log" 2>&1; rc=$?
    s_rpm="${S_RPM_FPR,,}"
    grep -q "is signed by ${s_rpm: -16}, not $S_IDX_FPR" "$work/log"; m=$?
    expect "2. ($slug) signed by S_RPM, SIGNER=S_IDX: 'signed by ... not ...'" "1 0" "$rc $m"
done

# 3. an rpm slipped in after signing
d3="$work/d3"; mkdir -p "$d3"; command cp -f "$d1"/*.rpm "$d3/"
command cp -f "$fx/x-1.0-1.noarch.fedora43.rpm" "$d3/z-1.0-1.noarch.fedora43.rpm"
"$tool" --dir "$d3" --keyset rehearsal --verify-only >"$work/log" 2>&1; rc=$?
grep -q 'z-1.0-1.noarch.fedora43.rpm does not verify' "$work/log"; m=$?
expect "3. an unsigned rpm added after signing does not verify" "1 0" "$rc $m"

# 4. S_RPM revoked: the already signed package must not verify, in both rpms
for img in F43:dnf:fedora43 TW:zypper:opensusetw; do
    IFS=: read -r iv mgr slug <<<"$img"
    d="$work/d4-$slug"; mkdir -p "$d"; command cp -f "$d1/x-1.0-1.noarch.$slug.rpm" "$d/"
    MODE=verify inside "${!iv}" "$mgr" "$d" revoked.asc "$S_RPM_FPR" >"$work/log" 2>&1; rc=$?
    sed 's/^/     /' "$work/log"
    grep -qiE 'revoked' "$work/log"; m=$?   # red for the revocation, not for any other reason
    expect "4. ($slug) a package signed by a revoked S_RPM is red, and says revoked" "1 0" "$rc $m"
    # control: what `rpm -K` says with the revoked certificate imported
    # shellcheck disable=SC2016  # expanded by the container's shell
    run -v "$d:/p" -v "$fx:/k:ro" "${!iv}" bash -c \
        'db=$(mktemp -d); rpmkeys --dbpath "$db" --import /k/revoked.asc && rpm --dbpath "$db" -K /p/*.rpm' >"$work/log" 2>&1
    rc=$?
    echo "     control ($slug) rpm -K with the revoked certificate imported: rc=$rc $(tail -n 1 "$work/log")"
done

# 5. signed by key B, judged against the rehearsal certificate
d5="$work/d5"; fresh "$d5" x-1.0-1.noarch.fedora43.rpm
MODE=sign inside "$F43" dnf "$d5" b.asc "$B_SIGNER" b.sec.asc >"$work/log" 2>&1
expect "5a. key B signs and verifies against its own certificate" 0 $?
"$tool" --dir "$d5" --keyset rehearsal --verify-only >"$work/log" 2>&1; rc=$?
grep -q 'does not verify' "$work/log"; m=$?
expect "5b. signed by key B, CERT is the rehearsal key: red" "1 0" "$rc $m"

# 6. a publish without its key cannot be judged
d6="$work/d6"; fresh "$d6" x-1.0-1.noarch.fedora43.rpm
"$tool" --dir "$d6" --keyset package-signing >"$work/log" 2>&1
expect "6a. --keyset package-signing without --key" 2 $?
cmp -s "$fx/x-1.0-1.noarch.fedora43.rpm" "$d6/x-1.0-1.noarch.fedora43.rpm"
expect "6b. ... and touched nothing" 0 $?
"$tool" --dir "$d6" --keyset nosuchset >"$work/log" 2>&1
expect "6c. an unknown key set" 2 $?
d6b="$work/d6b"; fresh "$d6b" y_1-1.deb13_all.debian13.deb
"$tool" --dir "$d6b" --keyset rehearsal >"$work/log" 2>&1
expect "6d. a directory with no rpm" 2 $?
d6c="$work/d6c"; mkdir -p "$d6c"; command cp -f "$fx/x-1.0-1.noarch.fedora43.rpm" "$d6c/x-1.0-1.noarch.nosuchslug.rpm"
"$tool" --dir "$d6c" --keyset rehearsal >"$work/log" 2>&1
expect "6e. an rpm of an unknown slug" 2 $?

# 7. control: `rpm -K` exits 0 for an unsigned package -- why it is never used
for img in F43:fedora43 TW:opensusetw; do
    IFS=: read -r iv slug <<<"$img"
    run -v "$fx:/k:ro" "${!iv}" rpm -K "/k/x-1.0-1.noarch.$slug.rpm" >"$work/log" 2>&1
    rc=$?   # before any other expansion resets $?
    control "7. ($slug) unsigned rpm, rpm -K: $(tail -n 1 "$work/log")" 0 "$rc"
done

[ "$fail" -eq 0 ] || { echo "selftest: $cases cases, $red red-proved"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
