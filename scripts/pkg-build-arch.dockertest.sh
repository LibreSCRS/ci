#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (makepkg runs in the archlinux tool image)
# Container self-test for the Arch family of pkg-gate.sh (pkg-build-arch.sh in
# `pkg-images tool-image archlinux`): two local fixture repositories, Lower and
# Upper, each with a recipe of the real shape -- its own source the signed tag
# git+https://github.com/LibreSCRS/<Repo>.git#tag=$pkgver?signed, a prepare()
# guard holding pkgver to VERSION -- and Upper locking Lower in deps.lock and
# depending on its package.
#
# Green: Lower builds; Upper builds against Lower's package, installed in the
# container first (its package() reads a file only Lower's package installs).
# Red: Upper whose package() installs a file its build never made (the shape
# of a recipe once published while packaging two files CMake did not install);
# a recipe whose VERSION is not its pkgver (the recipe's own guard); Upper with
# no Lower package built (no container is started).
#
# Network: pacman installs git, namcap and sudo from the Arch mirrors; the
# containers resolve github.com to loopback, so a makepkg that ignores the
# served tag fails to fetch instead of building the real repository's.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker is not on PATH -- cannot measure" >&2; exit 2; }
ARCH="$("$here/pkg-images" tool-image archlinux)" || exit 2
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-build-arch-dt.XXXXXX")" || exit 2
cleanup() {
    rm -rf "$work" 2>/dev/null \
        || { timeout -k 10 120 docker run --rm -v "$work:/w" "$ARCH" find /w -mindepth 1 -delete >/dev/null 2>&1; rm -rf "$work"; }
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_NOSYSTEM=1
unset REPO_ROOT GITHUB_WORKSPACE
log="$work/log"

cases=0; red=0; fail=0
expect() {  # expect <label> <want> <got> [needle in the log]
    cases=$((cases + 1))
    if [ "$2" = "$3" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" "$log"; }; then
        echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else
        echo "FAIL $1: want rc=$2${4:+ and \"$4\"}, got rc=$3"; tail -n 40 "$log" | sed 's/^/  | /'
        for b in "$work"/art*/log/build-*.txt; do [ -f "$b" ] && { echo "  -- $b"; tail -n 30 "$b" | sed 's/^/  | /'; }; done
        fail=1
    fi
}

recipe() {  # recipe <dir> <Repo> <pkgname> <package-body> [depends]
    cat >"$1/packaging/arch/PKGBUILD" <<EOF
# Maintainer: fixture <fixture@localhost>
pkgname=$3
pkgver=1.0.0
pkgrel=1
pkgdesc="pkg-build-arch container self-test fixture"
arch=('any')
license=('LGPL-2.1-or-later')
depends=($5)
makedepends=($5)
source=("git+https://github.com/LibreSCRS/$2.git#tag=\$pkgver?signed")
sha256sums=('SKIP')
validpgpkeys=('0000000000000000000000000000000000000000')
prepare() {
    [ "\$(head -n 1 "\$srcdir/$2/VERSION")" = "\$pkgver" ] || { echo "PACKAGING GUARD: VERSION is not pkgver" >&2; return 1; }
}
package() {
$4
}
EOF
}
repo() {  # repo <Repo> <pkgname> <package-body> [depends] [deps.lock]
    local d="$work/src/$1"
    rm -rf "$d"; mkdir -p "$d/packaging/arch"
    printf '1.0.0\n' >"$d/VERSION"
    printf 'data of %s\n' "$1" >"$d/data.txt"
    recipe "$d" "$1" "$2" "$3" "${4:-}"
    [ -z "${5:-}" ] || printf '%s\n' "$5" >"$d/deps.lock"
    git -C "$d" init -q -b main && git -C "$d" add -A && git -C "$d" commit -q -m c && git -C "$d" rev-parse HEAD
}
gate() {  # gate <art> <Repo>
    PKG_DOCKER_ADD_HOST=github.com:127.0.0.1 timeout -k 30 1800 "$here/pkg-gate.sh" --slug arch --art "$work/$1" --root "$work/src/$2" --name "$2" >"$log" 2>&1
}

lower_body='    install -Dm644 "$srcdir/Lower/data.txt" "$pkgdir/usr/share/librescrs-dt/lower.txt"'
upper_body='    test -f /usr/share/librescrs-dt/lower.txt
    install -Dm644 "$srcdir/Upper/data.txt" "$pkgdir/usr/share/librescrs-dt/upper.txt"'
L="$(repo Lower librescrs-dt-lower "$lower_body")"

gate art Lower; rc=$?
ls "$work/art/arch/Lower/arch/"librescrs-dt-lower-1.0.0-1-any.pkg.tar.zst >/dev/null 2>&1
expect "the recipe builds over the committed tree in the archlinux image" "0 0" "$rc $?" "G2 built 1 arch package(s)"

repo Upper librescrs-dt-upper "$upper_body" "'librescrs-dt-lower'" "Lower $work/src/Lower $L" >/dev/null
gate art Upper; rc=$?
ls "$work/art/arch/Upper/arch/"librescrs-dt-upper-1.0.0-1-any.pkg.tar.zst >/dev/null 2>&1
expect "an upper recipe builds against the lower package, installed first" "0 0" "$rc $?"

repo Upper librescrs-dt-upper "$upper_body
    install -Dm644 \"\$srcdir/Upper/never-built.so\" \"\$pkgdir/usr/lib/never-built.so\"" "'librescrs-dt-lower'" "Lower $work/src/Lower $L" >/dev/null
gate art Upper; expect "a recipe packaging a file its build never made is red" 1 $? "FAIL   G2 build"

repo Lower librescrs-dt-lower "$lower_body" >/dev/null
printf '1.0.1\n' >"$work/src/Lower/VERSION"; git -C "$work/src/Lower" commit -q -am drift
gate art2 Lower; expect "a recipe whose VERSION is not its pkgver is red (its own guard)" 1 $? "FAIL   G2 build"

repo Upper librescrs-dt-upper "$upper_body" "'librescrs-dt-lower'" "Lower $work/src/Lower $(git -C "$work/src/Lower" rev-parse HEAD)" >/dev/null
gate art3 Upper; expect "an upper recipe with no lower package built is red" 1 $? "upstream packages for Lower missing"

[ "$fail" -eq 0 ] || { echo "pkg-build-arch.dockertest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
