#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-images: the real lock is well-formed, and every way a lock
# can rot (short digest, moving tool URL, duplicate slug, unknown manager, a
# tool whose bytes changed) is a red, not a pass.
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-images"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-images-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

cases=0; red=0; fail=0
expect() {  # expect <name> <want-rc> <got-rc>
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then
        echo "ok   $1 (rc=$3)"
        [ "${3%% *}" = 1 ] && red=$((red + 1))
    else
        echo "FAIL $1: want rc=$2, got rc=$3"; fail=1
    fi
}
run() { "$tool" "$@" >"$work/out" 2>"$work/err"; }

# The lock this repository ships.
run check; expect "shipped lock is well-formed" 0 $?
run get debian13; rc=$?
grep -qE '^docker\.io/library/debian:13@sha256:[0-9a-f]{64}$' "$work/out"; expect "get debian13 prints a digest ref" "0 0" "$rc $?"
run family fedora44; expect "family fedora44 answers" 0 $?
[ "$(cat "$work/out")" = rpm ]; expect "fedora44 is rpm" 0 $?
run family ubuntu2604; [ "$(cat "$work/out")" = deb ]; expect "ubuntu2604 is deb" 0 $?
run manager opensusetw; [ "$(cat "$work/out")" = zypper ]; expect "opensusetw is zypper" 0 $?
run get nosuchslug; expect "unknown slug cannot be judged" 2 $?
run tool appimagetool; rc=$?
grep -q '/1\.9\.1/' "$work/out"; expect "tool appimagetool names its version" "0 0" "$rc $?"
PKG_IMAGES_LOCK="$work/absent" "$tool" check >/dev/null 2>&1; expect "missing lock cannot be judged" 2 $?

# Perturbations of a copy of the shipped lock.
lock="$here/../images.lock"
mut() {  # mut <name> <sed-expression> -> check over the mutated copy must be red
    sed -E "$2" "$lock" >"$work/lock"
    cmp -s "$lock" "$work/lock" && { echo "FAIL $1: the perturbation changed nothing"; fail=1; return; }
    PKG_IMAGES_LOCK="$work/lock" "$tool" check >/dev/null 2>&1
    expect "$1" 1 $?
}
mut "short digest is red"            's/^(image debian13 .*@sha256:[0-9a-f]{63})[0-9a-f]/\1/'
mut "tag without digest is red"      's/^(image fedora43 +dnf +[^@]+)@sha256:[0-9a-f]+/\1/'
mut "continuous tool url is red"     's#(tool appimagetool .*/download/)1\.9\.1/#\1continuous/#'
mut "unknown manager is red"         's/^(image fedora44 +)dnf/\1yum/'
mut "duplicate slug is red"          's/^image ubuntu2604 /image debian13 /'
mut "tool sum not 64 hex is red"     's/^(tool linuxdeploy .* )[0-9a-f]{64}$/\1abc/'
mut "unknown row kind is red"        's/^image leap160 /img leap160 /'

# refresh: a moved digest is rewritten, an unchanged one is not, and a tool
# whose bytes differ from the sum is red.
cp "$lock" "$work/lock"
cat >"$work/resolver" <<'EOF'
#!/usr/bin/env bash
case "$1:$2" in
  docker.io/library/fedora:44) echo "sha256:$(printf 'f%.0s' $(seq 64))" ;;
  *) grep -F " $1:$2@" "$PKG_IMAGES_LOCK" | sed -E 's/.*@//' ;;
esac
EOF
cat >"$work/fetch-good" <<'EOF'
#!/usr/bin/env bash
# The bytes whose sha256 the lock records are not available offline, so the
# good fetcher writes a file and the lock copy is rewritten to its sum below.
printf 'tool bytes for %s\n' "$1" >"$2"
EOF
cat >"$work/fetch-bad" <<'EOF'
#!/usr/bin/env bash
printf 'tampered bytes for %s\n' "$1" >"$2"
EOF
chmod +x "$work/resolver" "$work/fetch-good" "$work/fetch-bad"
# Rewrite the copy's tool sums to what fetch-good produces.
while read -r _ _ _ url sum; do
    s="$(printf 'tool bytes for %s\n' "$url" | sha256sum | cut -d' ' -f1)"
    sed -i "s|$sum\$|$s|" "$work/lock"
done < <(grep '^tool ' "$lock")
cp "$work/lock" "$work/lock.before"
PKG_IMAGES_LOCK="$work/lock" PKG_IMAGES_RESOLVER="$work/resolver" PKG_IMAGES_FETCH="$work/fetch-good" \
    "$tool" refresh --dry-run >"$work/out" 2>&1
rc=$?; cmp -s "$work/lock" "$work/lock.before"; expect "refresh --dry-run reports and writes nothing" "0 0" "$rc $?"
PKG_IMAGES_LOCK="$work/lock" PKG_IMAGES_RESOLVER="$work/resolver" PKG_IMAGES_FETCH="$work/fetch-good" \
    "$tool" refresh >"$work/out" 2>&1
rc=$?
grep -qE '^image fedora44 +dnf +docker\.io/library/fedora:44@sha256:f{64}$' "$work/lock"; moved=$?
grep -qF "$(grep '^image debian13 ' "$lock")" "$work/lock"; kept=$?
expect "refresh moves the moved digest and keeps the rest" "0 0 0" "$rc $moved $kept"
PKG_IMAGES_LOCK="$work/lock" "$tool" check >/dev/null 2>&1; expect "refreshed lock is still well-formed" 0 $?
PKG_IMAGES_LOCK="$work/lock" PKG_IMAGES_RESOLVER="$work/resolver" PKG_IMAGES_FETCH="$work/fetch-bad" \
    "$tool" refresh --dry-run >"$work/out" 2>&1
expect "refresh over tampered tool bytes is red" 1 $?
cat >"$work/resolver-down" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$work/resolver-down"
PKG_IMAGES_LOCK="$work/lock" PKG_IMAGES_RESOLVER="$work/resolver-down" PKG_IMAGES_FETCH="$work/fetch-good" \
    "$tool" refresh >"$work/out" 2>&1
expect "unreachable registry cannot be judged" 2 $?

[ "$fail" -eq 0 ] || { echo "pkg-images.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
