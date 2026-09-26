#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-build-deb.sh -- build a repository's Debian binary packages INSIDE the
# slug's container. Run by pkg-gate.sh.
#
# Contract: the exported source tree is the working directory; PKG_OUT (default
# /out) is writable and receives the .deb files and nothing else; PKG_UPSTREAM
# (default /upstream) holds already-built upstream .deb files, flat or one
# directory per repository; PKG_JOBS is the build parallelism (default 2).
#
# debian/changelog is generated here from CHANGELOG.md and VERSION by
# pkg-changelog-debian.sh, so the version, the maintainer and the entry text
# come from one place and the committed recipe cannot drift from them.
#
# No debug packages: noautodbgsym is added to whatever DEB_BUILD_OPTIONS the
# caller set, and a -dbgsym .deb or a .ddeb that appears anyway fails the build.
set -euo pipefail

here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
OUT="${PKG_OUT:-/out}"
UP="${PKG_UPSTREAM:-/upstream}"
JOBS="${PKG_JOBS:-2}"

export DEBIAN_FRONTEND=noninteractive
opts="${DEB_BUILD_OPTIONS:-}"
case " $opts " in *" parallel="*) ;; *) opts="$opts parallel=$JOBS" ;; esac
export DEB_BUILD_OPTIONS="${opts# } noautodbgsym"
echo "pkg-build-deb: DEB_BUILD_OPTIONS=$DEB_BUILD_OPTIONS"

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential dpkg-dev debhelper devscripts equivs ca-certificates >/dev/null

# Upstream LibreSCRS packages first: build dependencies are resolved against
# what is installed. A debug package is never an input.
shopt -s nullglob
upstream=()
for f in "$UP"/*.deb "$UP"/*/*.deb; do
    case "$f" in *-dbgsym_*|*.ddeb) echo "pkg-build-deb: refusing debug package input $f" >&2; exit 1 ;; esac
    upstream+=("$f")
done
shopt -u nullglob
if [ "${#upstream[@]}" -gt 0 ]; then
    echo "pkg-build-deb: installing ${#upstream[@]} upstream package(s)"
    printf '  %s\n' "${upstream[@]}"
    apt-get install -y -qq --no-install-recommends "${upstream[@]}" >/dev/null
fi

# dpkg-buildpackage reads debian/ at the root of the tree; the recipe lives
# under packaging/. A copy, not a symlink: some dpkg-source modes refuse one.
rm -rf debian
cp -a packaging/debian debian
chmod +x debian/rules
src="$(awk '/^Source:/{print $2; exit}' debian/control)"
[ -n "$src" ] || { echo "pkg-build-deb: debian/control names no Source" >&2; exit 1; }
REPO_ROOT="$PWD" bash "$here/pkg-changelog-debian.sh" "$src" debian/changelog
head -n 3 debian/changelog

# Build-Depends from debian/control itself.
mk-build-deps --install --remove \
    --tool 'apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends' \
    debian/control >/dev/null

dpkg-buildpackage -us -uc -b

shopt -s nullglob
built=( ../*.deb ../*.ddeb )
shopt -u nullglob
[ "${#built[@]}" -gt 0 ] || { echo "pkg-build-deb: dpkg-buildpackage produced no package" >&2; exit 1; }
for f in "${built[@]}"; do
    case "$f" in
        *-dbgsym_*|*.ddeb) echo "pkg-build-deb: debug package produced although disabled: $(basename "$f")" >&2; exit 1 ;;
    esac
done
mkdir -p "$OUT"
cp -v "${built[@]}" "$OUT/"
