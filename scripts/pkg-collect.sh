#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-collect.sh -- turn one slug's built packages into release assets.
#
# Usage: pkg-collect.sh <slug> <dest-dir> <src-dir>...
#
# Every .deb / .rpm under the source directories is copied to DEST as
#     <build-name-without-extension>.<slug>.<deb|rpm>
# e.g. liblibrescrs5_5.0.0-1_amd64.deb -> liblibrescrs5_5.0.0-1_amd64.debian13.deb.
# The slug is in the name because Debian 13 and Ubuntu 26.04 build different
# bytes under identical names; without it one release asset silently replaces
# the other, and a downstream `gh release download -p '*.<slug>.deb'` could not
# ask for the build made for its own distribution.
#
# Refused, with exit 1 and nothing half-copied left behind as a success:
#   * a debug package (-dbgsym_, .ddeb, -debuginfo-, -debugsource-): the
#     project does not publish debug symbols, and the build suppresses them;
#     one that arrives anyway is a build that ignored that, not an asset;
#   * a package of the other family (a .rpm on a deb slug, or the reverse);
#   * two inputs that want the same asset name;
#   * nothing at all -- a release that publishes a signed SHA256SUMS over zero
#     packages is how an empty build looks green.
# Other files (.changes, .buildinfo, logs) are listed as "not published".
#
# Exit codes: 0 collected, 1 refused, 2 cannot judge (usage, unknown slug).
set -uo pipefail
here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)" || exit 2

[ $# -ge 3 ] || { echo "usage: pkg-collect.sh <slug> <dest-dir> <src-dir>..." >&2; exit 2; }
slug="$1" dest="$2"; shift 2
family="$("$here/pkg-images" family "$slug")" || exit 2
for d in "$@"; do [ -d "$d" ] || { echo "pkg-collect: $d is not a directory" >&2; exit 2; }; done

mapfile -t files < <(find "$@" -type f \( -name '*.deb' -o -name '*.ddeb' -o -name '*.rpm' \) | sort)
bad=0
declare -A want=()
for f in "${files[@]}"; do
    base="$(basename "$f")"
    case "$base" in
        *-dbgsym_*|*.ddeb|*-debuginfo-*|*-debugsource-*)
            echo "REFUSED debug package: $f"; bad=1; continue ;;
    esac
    ext="${base##*.}"
    if [ "$ext" != "$family" ]; then
        echo "REFUSED $f: a .$ext on the $family slug $slug"; bad=1; continue
    fi
    stem="${base%.*}"
    case "$stem" in
        *."$slug") echo "REFUSED $f: already carries the slug -- collected twice?"; bad=1; continue ;;
    esac
    name="$stem.$slug.$ext"
    if [ -n "${want[$name]+x}" ]; then
        echo "REFUSED $f: asset name $name is also wanted by ${want[$name]}"; bad=1; continue
    fi
    want[$name]="$f"
done
[ "${#want[@]}" -gt 0 ] || { echo "REFUSED nothing to collect for $slug under: $*"; bad=1; }
[ "$bad" -eq 0 ] || { echo "pkg-collect: refused -- nothing copied"; exit 1; }

mkdir -p "$dest" || exit 2
for name in "${!want[@]}"; do
    if [ -e "$dest/$name" ]; then echo "REFUSED $dest/$name already exists"; exit 1; fi
done
for name in $(printf '%s\n' "${!want[@]}" | sort); do
    cp -- "${want[$name]}" "$dest/$name" || exit 2
    echo "asset  $name"
done
find "$@" -type f ! \( -name '*.deb' -o -name '*.rpm' -o -name '.built-from' \) -printf '  not published: %p\n' | sort
echo "PKG_COLLECT_COUNT=${#want[@]}"
