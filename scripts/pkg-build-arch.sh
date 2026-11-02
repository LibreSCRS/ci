#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-build-arch.sh -- build a repository's Arch packages from its committed
# packaging/arch/PKGBUILD INSIDE the archlinux tool image. Run by pkg-gate.sh
# for the pseudo-slug `arch`.
#
# Contract: the exported source tree (the committed HEAD, no .git) is the
# working directory; PKG_OUT (default /out) is writable and receives the
# *.pkg.tar.zst files and nothing else; PKG_UPSTREAM (default /upstream) holds
# already-built upstream packages, flat or one directory per repository;
# PKG_JOBS is the build parallelism (default 2).
#
# The recipe is built as the AUR publishes it: byte for byte, by makepkg, as
# an unprivileged user. Its own source is the repository's signed release tag
# (`git+https://github.com/LibreSCRS/<Repo>.git#tag=$pkgver?signed`), which does
# not exist before the release, so that one source is served locally: the
# exported tree is committed into a repository whose tag $pkgver is that
# commit, and makepkg's git (MAKEPKG_GIT_CONFIG) resolves
# https://github.com/LibreSCRS/ to it. The tag carries no signature, so
# --skippgpcheck; the signature is checked where it exists, by the AUR step on
# the real tag. Submodule contents are left out of that commit, as a checkout
# of the tag leaves them out: what the recipe fetches for them is what builds.
# Every other source is downloaded as an AUR user's makepkg would.
#
# After makepkg, the checkout it built from (src/<dir>) must be the served
# commit. A makepkg whose git does not read MAKEPKG_GIT_CONFIG reaches the
# real host instead: before the release that fails for a missing tag, but once
# the tag exists (a re-run, a manual dispatch) it builds the published tag --
# green over a tree this run never committed. That is refused here. Where
# that checkout lies is set by this script, not the image: BUILDDIR is the
# recipe's directory (makepkg then uses its src/), given in makepkg's
# environment, which no makepkg.conf overrides. No checkout there cannot be
# judged and says so, apart from a checkout of another commit.
#
# makepkg -s --noconfirm --nocheck: dependencies from the distribution, the
# upstream packages installed first with pacman -U, the recipe's check() not
# run (the tests run in each repository's own CI). No debug packages: the
# builder's makepkg.conf ends with OPTIONS+=(!debug), and a *-debug-* package
# that appears anyway, or is offered as input, fails the build.
#
# namcap reads the recipe and every package it built; its findings are printed
# and not judged here.
#
# Environment for the self-test: PKG_ARCH_HOME (default /home/builder) is the
# builder's home; PKG_ARCH_ROOTLESS=1 skips the steps only root can take
# (pacman, the user, sudo, chown).
#
# Exit codes: 0 built, 1 the recipe or its build failed, 2 cannot judge.
set -euo pipefail

OUT="${PKG_OUT:-/out}"
UP="${PKG_UPSTREAM:-/upstream}"
JOBS="${PKG_JOBS:-2}"
B="${PKG_ARCH_HOME:-/home/builder}"
ROOTLESS="${PKG_ARCH_ROOTLESS:-}"
TREE="$(pwd)"

die() { echo "pkg-build-arch: $2" >&2; exit "$1"; }
[ -f "$TREE/packaging/arch/PKGBUILD" ] || die 1 "no packaging/arch/PKGBUILD in the tree"
mkdir -p "$OUT" || die 2 "cannot create $OUT"

shopt -s nullglob
upstream=()
for f in "$UP"/*.pkg.tar.* "$UP"/*/*.pkg.tar.*; do
    case "$(basename "$f")" in *.sig) continue ;; *-debug-*) die 1 "refusing debug package input $f" ;; esac
    upstream+=("$f")
done
shopt -u nullglob

as_builder() {
    if [ -n "$ROOTLESS" ]; then env HOME="$B" "$@"; return; fi
    runuser -u builder -- env HOME="$B" USER=builder LOGNAME=builder "$@"
}

if [ -z "$ROOTLESS" ]; then
    timeout -k 30 1200 pacman -Syu --noconfirm --needed git namcap sudo >/dev/null \
        || die 2 "pacman could not install git, namcap and sudo"
    if [ "${#upstream[@]}" -gt 0 ]; then
        echo "pkg-build-arch: installing ${#upstream[@]} upstream package(s)"
        timeout -k 30 1200 pacman -U --noconfirm "${upstream[@]}" || die 1 "the upstream packages do not install"
    fi
    id -u builder >/dev/null 2>&1 || useradd -m -d "$B" builder || die 2 "useradd could not create builder"
    # makepkg -s installs the recipe's dependencies through sudo pacman.
    printf 'builder ALL=(root) NOPASSWD: /usr/bin/pacman\n' >/etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
fi
mkdir -p "$B"

# The recipe as makepkg parses it: its version, and its own source.
info="$(cd "$TREE/packaging/arch" && bash -c 'source ./PKGBUILD >/dev/null 2>&1; printf "pkgver=%s\n" "$pkgver"; printf "source=%s\n" "${source[@]}"')" \
    || die 1 "the PKGBUILD does not source"
pkgver="$(printf '%s\n' "$info" | sed -n 's/^pkgver=//p')"
[ -n "$pkgver" ] || die 1 "the PKGBUILD sets no pkgver"
mapfile -t own < <(printf '%s\n' "$info" | sed -n 's/^source=//p' \
    | sed -nE 's#^(([^:]*)::)?git\+https://github\.com/LibreSCRS/([A-Za-z0-9._-]+)\.git\#tag=([^?]+)(\?signed)?$#\3 \4 \2#p')
[ "${#own[@]}" -eq 1 ] \
    || die 1 "the PKGBUILD must build exactly one LibreSCRS signed tag (git+https://github.com/LibreSCRS/<Repo>.git#tag=\$pkgver?signed); it names ${#own[@]}"
read -r repo tag srcdir <<<"${own[0]}"
srcdir="${srcdir:-$repo}"   # makepkg's directory for it: the name before ::, else the repository
[ "$tag" = "$pkgver" ] || die 1 "the recipe's own source is tag '$tag', not pkgver $pkgver"
echo "pkg-build-arch: $repo $pkgver, the tag served from the committed tree"

# The tree a checkout of the tag would give: committed, submodules empty.
rm -rf "$B/tree" "$B/git" "$B/build" "$B/pkgs" "$B/src-cache"
cp -a "$TREE/." "$B/tree"
if [ -f "$B/tree/.gitmodules" ]; then
    while read -r _ path; do
        [ -n "$path" ] && [ -d "$B/tree/$path" ] && find "$B/tree/$path" -mindepth 1 -delete
    done < <(git config -f "$B/tree/.gitmodules" --get-regexp '\.path$' || true)
fi
mkdir -p "$B/git" "$B/build" "$B/pkgs" "$B/src-cache"
cp -a "$TREE/packaging/arch/." "$B/build/"
cat >"$B/gitconfig" <<EOF
[url "file://$B/git/"]
	insteadOf = https://github.com/LibreSCRS/
[protocol "file"]
	allow = always
[user]
	name = pkg-build-arch
	email = pkg-build-arch@localhost
[init]
	defaultBranch = main
EOF
cat >"$B/.makepkg.conf" <<EOF
OPTIONS+=(!debug)
MAKEFLAGS="-j$JOBS"
PKGDEST="$B/pkgs"
SRCDEST="$B/src-cache"
EOF
[ -n "$ROOTLESS" ] || chown -R builder: "$B"

# shellcheck disable=SC2016  # the script runs in the builder's shell, which expands it
as_builder env GIT_CONFIG_GLOBAL="$B/gitconfig" GIT_CONFIG_NOSYSTEM=1 bash -c '
    set -e
    cd "$1/tree"
    git init -q .
    git add -A -f
    git -c commit.gpgsign=false commit -q -m "release candidate $2"
    git tag "$2"
    git clone -q --bare . "$1/git/$3.git"
' _ "$B" "$pkgver" "$repo" || die 2 "could not serve tag $pkgver of $repo"

start=$(date +%s)
rc=0
( cd "$B/build" && as_builder env MAKEPKG_GIT_CONFIG="$B/gitconfig" BUILDDIR="$B/build" \
      makepkg -s --noconfirm --nocheck --skippgpcheck ) || rc=$?
echo "pkg-build-arch: makepkg rc=$rc in $((($(date +%s) - start) / 60)) min"
[ "$rc" -eq 0 ] || die 1 "makepkg failed over the committed recipe (rc=$rc)"

git_b() { as_builder env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
served="$(git_b --git-dir="$B/git/$repo.git" rev-parse --verify -q "refs/tags/$pkgver^{commit}")" \
    || die 2 "the served repository has no tag $pkgver"
built="$(git_b -C "$B/build/src/$srcdir" rev-parse --verify -q HEAD 2>/dev/null)" || built=""
[ -n "$built" ] \
    || die 2 "makepkg left no checkout at src/$srcdir -- cannot tell which commit it built"
[ "$built" = "$served" ] \
    || die 1 "makepkg built $built, not the served commit $served of tag $pkgver -- its git did not read MAKEPKG_GIT_CONFIG"
echo "pkg-build-arch: built the served commit $served"

shopt -s nullglob
built=("$B"/pkgs/*.pkg.tar.*)
shopt -u nullglob
pkgs=()
for f in ${built[@]+"${built[@]}"}; do
    case "$(basename "$f")" in *.sig) continue ;; *-debug-*) die 1 "makepkg produced a debug package: $(basename "$f")" ;; esac
    pkgs+=("$f")
done
[ "${#pkgs[@]}" -gt 0 ] || die 1 "makepkg produced no package"

if command -v namcap >/dev/null 2>&1; then
    { namcap "$B/build/PKGBUILD"; for f in "${pkgs[@]}"; do namcap "$f"; done; } 2>&1 | sed 's/^/namcap: /' || true
else
    echo "pkg-build-arch: namcap is not installed -- not run"
fi

cp "${pkgs[@]}" "$OUT/"
echo "pkg-build-arch: ${#pkgs[@]} package(s)"
for f in "${pkgs[@]}"; do echo "  $(basename "$f")"; done
