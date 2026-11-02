#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-build-arch.sh without a container (PKG_ARCH_ROOTLESS=1):
# makepkg and namcap are stubs, git is real. The stub makepkg fetches the
# recipe's own source the way makepkg does -- a mirror in SRCDEST through
# MAKEPKG_GIT_CONFIG, checked out at the tag under src/<dir> -- so the green
# case proves the tag is served from the committed tree, at pkgver, with the
# submodule's contents left out and a tracked-but-ignored file kept. A makepkg
# that reaches the real host instead (a stub ignoring MAKEPKG_GIT_CONFIG, with
# a "github" fixture whose tag $pkgver is another commit) is red, although it
# builds. An image that moves makepkg's BUILDDIR (its makepkg.conf or its
# environment) is still judged in the recipe's src/, and no checkout there is
# "cannot judge", not a wrong commit. A recipe that does not build its own
# signed tag at pkgver, a failed makepkg, a debug package (built or offered),
# and no package at all are each red.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-build-arch.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-build-arch-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_NOSYSTEM=1

cases=0; red=0; fail=0
expect() {  # expect <label> <want> <got> [needle in the log]
    cases=$((cases + 1))
    if [ "$2" = "$3" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" "$work/log"; }; then
        echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2${4:+ and \"$4\"}, got rc=$3"; tail -n 20 "$work/log" | sed 's/^/  | /'; fail=1; fi
}

mkdir -p "$work/bin"
cat >"$work/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
echo "$*" >"$STUB_REC/args"
# makepkg's order: the environment's BUILDDIR wins over every makepkg.conf
# (the image's, then the user's); unset, it is the recipe's directory.
env_builddir="${BUILDDIR:-}"
# shellcheck disable=SC1090
[ -z "${STUB_SYSTEM_CONF:-}" ] || . "$STUB_SYSTEM_CONF"
# shellcheck disable=SC1091
. "$HOME/.makepkg.conf"
BUILDDIR="${env_builddir:-${BUILDDIR:-$PWD}}"
printf '%s\n' "${OPTIONS[@]}" >"$STUB_REC/options"
# shellcheck disable=SC1091
. ./PKGBUILD
if [ "$BUILDDIR" -ef "$PWD" ]; then srcroot="$BUILDDIR/src"; else srcroot="$BUILDDIR/$pkgname/src"; fi
dir="${STUB_DIR:-Fixture}"
cfg="$MAKEPKG_GIT_CONFIG"; [ -z "${STUB_ESCAPE:-}" ] || cfg="$STUB_ESCAPE"
GIT_CONFIG_GLOBAL="$cfg" git clone -q --mirror "https://github.com/LibreSCRS/Fixture.git" "$SRCDEST/$dir" || exit 1
git --git-dir="$SRCDEST/$dir" ls-tree -r --name-only "refs/tags/$pkgver" >"$STUB_REC/files" || exit 1
if [ -z "${STUB_NOCHECKOUT:-}" ]; then
    mkdir -p "$srcroot" && git clone -q -s "$SRCDEST/$dir" "$srcroot/$dir" && git -C "$srcroot/$dir" checkout -q "tags/$pkgver" || exit 1
fi
[ -z "${STUB_MAKEPKG_RC:-}" ] || exit "$STUB_MAKEPKG_RC"
[ -n "${STUB_NONE:-}" ] || printf 'zst\n' >"$PKGDEST/fixture-$pkgver-1-x86_64.pkg.tar.zst"
[ -z "${STUB_DEBUG:-}" ] || printf 'dbg\n' >"$PKGDEST/fixture-debug-$pkgver-1-x86_64.pkg.tar.zst"
exit 0
EOF
cat >"$work/bin/namcap" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$STUB_REC/namcap"
echo "$(basename "$1") W: a finding namcap prints"
EOF
chmod +x "$work/bin"/*

# The real host, as a makepkg that ignored MAKEPKG_GIT_CONFIG would reach it:
# tag 5.0.0 exists there, at a commit that is not the committed tree.
mkdir -p "$work/github/src"
printf 'published\n' >"$work/github/src/VERSION"
( export GIT_CONFIG_GLOBAL=/dev/null; cd "$work/github/src" && git init -q && git add -A \
  && git -c user.name=g -c user.email=g@g commit -q -m published && git tag 5.0.0 \
  && git clone -q --bare . "$work/github/Fixture.git" ) || exit 2
printf '[url "file://%s/github/"]\n\tinsteadOf = https://github.com/LibreSCRS/\n[protocol "file"]\n\tallow = always\n' "$work" >"$work/github.gitconfig"

tree() {  # tree [source-line]: the exported tree of a repository with a submodule
    local src=${1:-}
    # shellcheck disable=SC2016  # $pkgver is the recipe's, expanded by makepkg
    [ -n "$src" ] || src='"git+https://github.com/LibreSCRS/Fixture.git#tag=$pkgver?signed"'
    rm -rf "$work/t" "$work/out" "$work/up" "$work/rec" "$work/home"
    mkdir -p "$work/t/packaging/arch" "$work/t/thirdparty/sub" "$work/out" "$work/up" "$work/rec" "$work/home"
    cat >"$work/t/packaging/arch/PKGBUILD" <<EOF
pkgname=fixture
pkgver=5.0.0
pkgrel=1
source=($src
        "other.tar.gz::https://example.org/other.tar.gz")
EOF
    printf '5.0.0\n' >"$work/t/VERSION"
    printf '[submodule "thirdparty/sub"]\n\tpath = thirdparty/sub\n\turl = https://example.org/sub.git\n' >"$work/t/.gitmodules"
    printf 'vendored\n' >"$work/t/thirdparty/sub/file"
    printf 'generated.h\n' >"$work/t/.gitignore"
    printf 'tracked although ignored\n' >"$work/t/generated.h"
}
build() {
    ( cd "$work/t" && env PATH="$work/bin:$PATH" STUB_REC="$work/rec" PKG_OUT="$work/out" PKG_UPSTREAM="$work/up" \
        PKG_ARCH_HOME="$work/home" PKG_ARCH_ROOTLESS=1 PKG_JOBS=4 "$@" bash "$tool" ) >"$work/log" 2>&1
}

tree; build; rc=$?
test -f "$work/out/fixture-5.0.0-1-x86_64.pkg.tar.zst"; out=$?
grep -qx -- '-s --noconfirm --nocheck --skippgpcheck' "$work/rec/args"; args=$?
expect "the recipe builds over the committed tree, as makepkg -s --nocheck" "0 0 0" "$rc $out $args"
grep -qx VERSION "$work/rec/files" && grep -qx generated.h "$work/rec/files" && ! grep -q '^thirdparty/sub/' "$work/rec/files"
expect "the served tag is the tree at pkgver: ignored-but-tracked kept, submodule contents left out" 0 $?
test "$(tail -n 1 "$work/rec/options")" = '!debug'; expect "the builder's makepkg.conf turns debug packages off" 0 $?
test "$(wc -l <"$work/rec/namcap")" -eq 2 && grep -q '^namcap: .* W: a finding namcap prints' "$work/log"
expect "namcap reads the recipe and the package, and is printed" 0 $?

tree '"fx::git+https://github.com/LibreSCRS/Fixture.git#tag=$pkgver?signed"'; build STUB_DIR=fx
expect "a recipe naming its own source's directory is judged in that directory" 0 $? "built the served commit"
tree; build STUB_ESCAPE="$work/github.gitconfig"; rc=$?
test -z "$(ls -A "$work/out")"
expect "a makepkg that built the real host's tag, not the served one, is red, and nothing is collected" "1 0" "$rc $?" "not the served commit"
# Where makepkg checks the source out is the script's to say, not the image's.
printf 'BUILDDIR=%s/elsewhere\n' "$work" >"$work/image-makepkg.conf"
tree; build STUB_SYSTEM_CONF="$work/image-makepkg.conf"
expect "an image whose makepkg.conf moves BUILDDIR is judged in the recipe's src/" 0 $? "built the served commit"
tree; build BUILDDIR="$work/elsewhere"
expect "an image whose environment moves BUILDDIR is judged in the recipe's src/" 0 $? "built the served commit"
tree; build STUB_NOCHECKOUT=1; rc=$?
! grep -q 'did not read MAKEPKG_GIT_CONFIG' "$work/log" && test -z "$(ls -A "$work/out")"
expect "no checkout at src/<dir> cannot be judged, is not blamed on the git config, and nothing is collected" "2 0" "$rc $?" "left no checkout at src/Fixture"

tree '"git+https://github.com/LibreSCRS/Fixture.git#branch=main"'; build
expect "a recipe building a branch, not its tag, is red" 1 $? "must build exactly one LibreSCRS signed tag"
tree '"git+https://github.com/LibreSCRS/Fixture.git#tag=v$pkgver?signed"'; build
expect "a recipe whose tag is not pkgver is red" 1 $? "not pkgver 5.0.0"
tree '"git+https://github.com/LibreSCRS/Fixture.git#tag=$pkgver?signed" "git+https://github.com/LibreSCRS/Other.git#tag=$pkgver?signed"'; build
expect "a recipe building two LibreSCRS tags is red" 1 $? "it names 2"
tree; build STUB_MAKEPKG_RC=4; expect "a failed makepkg is red" 1 $? "makepkg failed"
tree; build STUB_DEBUG=1; rc=$?
test -z "$(ls -A "$work/out")"; expect "a debug package is red, and nothing is collected" "1 0" "$rc $?"
tree; build STUB_NONE=1; expect "no package at all is red" 1 $? "produced no package"
tree; mkdir -p "$work/up/LibreMiddleware"; printf 'x\n' >"$work/up/LibreMiddleware/lm-debug-5.0.0-1-x86_64.pkg.tar.zst"; build
expect "a debug package offered as upstream input is red" 1 $? "refusing debug package input"
tree; rm "$work/t/packaging/arch/PKGBUILD"; build; expect "no recipe is red" 1 $? "no packaging/arch/PKGBUILD"

[ "$fail" -eq 0 ] || { echo "pkg-build-arch.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
