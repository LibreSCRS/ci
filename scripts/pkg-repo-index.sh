#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-repo-index.sh -- the package-index tools, run in their own images.
#
# Usage: pkg-repo-index.sh fields <dir>          dpkg-deb -f of every .deb under
#                                                <dir>: path<TAB>Package<TAB>Version<TAB>Architecture
#        pkg-repo-index.sh deb <tree> <codename> Packages and Packages.xz of
#                                                <tree>/deb/pool/<codename> (apt-ftparchive)
#        pkg-repo-index.sh rpm <tree> <slug>     repodata of <tree>/rpm/<slug> (createrepo_c,
#                                                zstd; PKG_REPO_REVISION fixes the revision)
# deb and fields run in the debian13 image, rpm in fedora43 (pkg-images get).
# Containers are named pkg-repo-idx-$$-* and removed on exit; what they write
# is handed back to the caller's uid.
#
# Environment: PKG_DOCKER, PKG_DOCKER_NETWORK as pkg-gate.sh.
# Exit codes: 0 done, 2 cannot judge.
set -uo pipefail

here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)" || exit 2
die2() { echo "pkg-repo-index: $* -- cannot judge" >&2; exit 2; }
DOCKER="${PKG_DOCKER:-docker}"
command -v "$DOCKER" >/dev/null 2>&1 || die2 "$DOCKER is not on PATH"
NET=()
[ -z "${PKG_DOCKER_NETWORK:-}" ] || NET=(--network "$PKG_DOCKER_NETWORK")
own="$(id -u):$(id -g)"
cname="pkg-repo-idx-$$-$RANDOM"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { "$DOCKER" rm -f "$cname" >/dev/null 2>&1; }
trap cleanup EXIT
trap 'exit 2' HUP INT TERM

mode="${1:-}"
case "$mode" in
    fields)
        [ $# -eq 2 ] && [ -d "$2" ] || die2 "usage: fields <dir>"
        dir="$(cd -- "$2" && pwd)"
        img="$("$here/pkg-images" get debian13)" || die2 "no debian13 image"
        # shellcheck disable=SC2016  # the script runs in the container; its $ are not ours
        "$DOCKER" run --rm --name "$cname" "${NET[@]}" -v "$dir:/in:ro" "$img" bash -c '
            cd /in && find . -name "*.deb" | LC_ALL=C sort | while IFS= read -r f; do
                printf "%s\t%s\t%s\t%s\n" "${f#./}" "$(dpkg-deb -f "$f" Package)" "$(dpkg-deb -f "$f" Version)" "$(dpkg-deb -f "$f" Architecture)"
            done' || die2 "dpkg-deb failed"
        ;;
    deb)
        [ $# -eq 3 ] && [ -d "$2/deb/pool/$3" ] || die2 "usage: deb <tree> <codename> (with <tree>/deb/pool/<codename>)"
        tree="$(cd -- "$2" && pwd)"
        img="$("$here/pkg-images" get debian13)" || die2 "no debian13 image"
        # shellcheck disable=SC2016  # the script runs in the container; its $ are not ours
        "$DOCKER" run --rm --name "$cname" "${NET[@]}" -v "$tree:/t" -e "CODENAME=$3" -e "OWN=$own" "$img" bash -c '
            set -eu
            trap "chown -R \"$OWN\" /t" EXIT
            export DEBIAN_FRONTEND=noninteractive LC_ALL=C
            apt-get update -qq >/dev/null
            apt-get install -y -qq --no-install-recommends apt-utils xz-utils >/dev/null
            cd /t/deb
            d="dists/$CODENAME/main/binary-amd64"; mkdir -p "$d"
            apt-ftparchive packages "pool/$CODENAME" >"$d/Packages"
            xz -9 -c "$d/Packages" >"$d/Packages.xz"' || die2 "apt-ftparchive for $3 failed"
        ;;
    rpm)
        [ $# -eq 3 ] && [ -d "$2/rpm/$3" ] || die2 "usage: rpm <tree> <slug> (with <tree>/rpm/<slug>)"
        tree="$(cd -- "$2" && pwd)"
        img="$("$here/pkg-images" get fedora43)" || die2 "no fedora43 image"
        # shellcheck disable=SC2016  # the script runs in the container; its $ are not ours
        "$DOCKER" run --rm --name "$cname" "${NET[@]}" -v "$tree:/t" -e "SLUG=$3" -e "OWN=$own" \
            -e "REVISION=${PKG_REPO_REVISION:-}" "$img" bash -c '
            set -eu
            trap "chown -R \"$OWN\" /t" EXIT
            dnf -y -q install createrepo_c >/dev/null
            rev=()
            [ -z "$REVISION" ] || rev=(--revision "$REVISION" --set-timestamp-to-revision)
            createrepo_c -q --general-compress-type=zstd "${rev[@]}" "/t/rpm/$SLUG"' || die2 "createrepo_c for $3 failed"
        ;;
    *) die2 "usage: pkg-repo-index.sh fields|deb|rpm ..." ;;
esac
