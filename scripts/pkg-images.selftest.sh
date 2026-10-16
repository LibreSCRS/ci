#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-images: the real lock is well-formed, and every way a lock
# can rot (short digest, duplicate slug, unknown manager, a row kind it does
# not know) is a red, not a pass.
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
mut "unknown manager is red"         's/^(image fedora44 +)dnf/\1yum/'
mut "duplicate slug is red"          's/^image ubuntu2604 /image debian13 /'
mut "unknown row kind is red"        's/^image leap160 /img leap160 /'
# The AppImage tool rows went with the AppImage; one left behind is not a pass.
zeros="$(printf '0%.0s' $(seq 64))"
mut "a tool row is red"              "\$a tool appimagetool 1.9.1 https://example.invalid/1.9.1/a $zeros"

# refresh: a moved digest is rewritten, an unchanged one is not.
cp "$lock" "$work/lock"
cat >"$work/resolver" <<'EOF'
#!/usr/bin/env bash
case "$1:$2" in
  docker.io/library/fedora:44) echo "sha256:$(printf 'f%.0s' $(seq 64))" ;;
  *) grep -F " $1:$2@" "$PKG_IMAGES_LOCK" | sed -E 's/.*@//' ;;
esac
EOF
chmod +x "$work/resolver"
cp "$work/lock" "$work/lock.before"
PKG_IMAGES_LOCK="$work/lock" PKG_IMAGES_RESOLVER="$work/resolver" \
    "$tool" refresh --dry-run >"$work/out" 2>&1
rc=$?; cmp -s "$work/lock" "$work/lock.before"; expect "refresh --dry-run reports and writes nothing" "0 0" "$rc $?"
PKG_IMAGES_LOCK="$work/lock" PKG_IMAGES_RESOLVER="$work/resolver" \
    "$tool" refresh >"$work/out" 2>&1
rc=$?
grep -qE '^image fedora44 +dnf +docker\.io/library/fedora:44@sha256:f{64}$' "$work/lock"; moved=$?
grep -qF "$(grep '^image debian13 ' "$lock")" "$work/lock"; kept=$?
expect "refresh moves the moved digest and keeps the rest" "0 0 0" "$rc $moved $kept"
PKG_IMAGES_LOCK="$work/lock" "$tool" check >/dev/null 2>&1; expect "refreshed lock is still well-formed" 0 $?
cat >"$work/resolver-down" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$work/resolver-down"
PKG_IMAGES_LOCK="$work/lock" PKG_IMAGES_RESOLVER="$work/resolver-down" \
    "$tool" refresh >"$work/out" 2>&1
expect "unreachable registry cannot be judged" 2 $?

# tool-image rows: a container a CI step runs a tool in, never a slug.
ti_ref="docker.io/library/archlinux:base-devel@sha256:$(printf 'a%.0s' $(seq 64))"
tilock() {  # tilock <row>... -> $work/tl = the shipped lock without tool-image rows, plus the given rows
    grep -v '^tool-image' "$lock" >"$work/tl"
    local r; for r in "$@"; do printf '%s\n' "$r" >>"$work/tl"; done
}
tl() { PKG_IMAGES_LOCK="$work/tl" "$tool" "$@" >"$work/out" 2>"$work/err"; }
tilock "tool-image archlinux $ti_ref"
tl check; expect "a lock with a tool-image row is well-formed" 0 $?
tl tool-image archlinux; rc=$?; [ "$(cat "$work/out")" = "$ti_ref" ]; expect "tool-image prints the ref" "0 0" "$rc $?"
tl slugs; ! grep -q archlinux "$work/out"; expect "slugs never prints a tool-image" 0 $?
tl get archlinux; expect "get does not answer for a tool-image" 2 $?
tl tool-image nema; expect "unknown tool-image cannot be judged" 2 $?
tilock "tool-image archlinux docker.io/library/archlinux:base-devel"
tl check; expect "tool-image without a digest is red" 1 $?
tilock "tool-image archlinux $ti_ref" "tool-image archlinux $ti_ref"
tl check; expect "duplicate tool-image is red" 1 $?
tilock "tool-image archlinux $ti_ref extra"
tl check; expect "tool-image with a trailing field is red" 1 $?

# add: resolves ONE digest and appends ONE row; the rest stays byte-identical.
cat >"$work/resolver-add" <<'EOF'
#!/usr/bin/env bash
echo "sha256:$(printf 'b%.0s' $(seq 64))"
EOF
chmod +x "$work/resolver-add"
grep -v '^tool-image' "$lock" >"$work/tl"; cp "$work/tl" "$work/tl.before"
PKG_IMAGES_LOCK="$work/tl" PKG_IMAGES_RESOLVER="$work/resolver-add" "$tool" add tool-image x docker.io/library/x:1 >"$work/out" 2>&1
rc=$?
[ "$(wc -l <"$work/tl")" -eq "$(( $(wc -l <"$work/tl.before") + 1 ))" ]; n=$?
head -n "$(wc -l <"$work/tl.before")" "$work/tl" | cmp -s - "$work/tl.before"; same=$?
tail -n 1 "$work/tl" | grep -qE '^tool-image +x +docker\.io/library/x:1@sha256:b{64}$'; row=$?
expect "add appends exactly one row and leaves the rest identical" "0 0 0 0" "$rc $n $same $row"
tl check; expect "the lock after add is well-formed" 0 $?
PKG_IMAGES_LOCK="$work/tl" PKG_IMAGES_RESOLVER="$work/resolver-add" "$tool" add tool-image x docker.io/library/x:1 >/dev/null 2>&1
expect "add refuses a name already present" 1 $?
cp "$work/tl" "$work/tl.before"
PKG_IMAGES_LOCK="$work/tl" PKG_IMAGES_RESOLVER="$work/resolver-add" "$tool" add tool-image y 'docker.io/library/y' >/dev/null 2>&1
expect "add refuses a ref without a tag" 2 $?
PKG_IMAGES_LOCK="$work/tl" PKG_IMAGES_RESOLVER="$work/resolver-down" "$tool" add tool-image z docker.io/library/z:1 >/dev/null 2>&1
rc=$?; cmp -s "$work/tl" "$work/tl.before"; expect "add with the registry down writes nothing" "2 0" "$rc $?"
PKG_IMAGES_LOCK="$work/tl" PKG_IMAGES_RESOLVER="$work/resolver-add" "$tool" add image z apt docker.io/library/z:1 >/dev/null 2>&1
expect "add knows only tool-image" 2 $?

# refresh rewrites a tool-image digest too.
tilock "tool-image archlinux $ti_ref"
PKG_IMAGES_LOCK="$work/tl" PKG_IMAGES_RESOLVER="$work/resolver-add" "$tool" refresh >/dev/null 2>&1
rc=$?; grep -qE '^tool-image +archlinux +docker\.io/library/archlinux:base-devel@sha256:b{64}$' "$work/tl"
expect "refresh moves a tool-image digest" "0 0" "$rc $?"

[ "$fail" -eq 0 ] || { echo "pkg-images.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
