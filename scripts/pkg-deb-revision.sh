#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-deb-revision.sh -- the Debian revision of a package built on this
# distribution: 1~deb13 on Debian 13, 1~ubuntu26.04 on Ubuntu 26.04.
#
# One version string with different bytes per distribution is a version apt,
# an administrator's mirror and `apt-cache policy` cannot tell apart, and an
# upgrade of the distribution keeps the old build because the version did not
# move. The suffix sorts below the bare revision (~), as in other vendors'
# repositories.
#
# Usage: pkg-deb-revision.sh [os-release]     (default /etc/os-release)
#        DEB_REVISION_BASE (default 1) is the part before the ~.
# Exit: 0 printed; 2 cannot judge (unreadable file, a distribution this does
#       not name -- a derivative is never guessed from ID_LIKE).
set -uo pipefail
f="${1:-/etc/os-release}"
[ -r "$f" ] || { echo "pkg-deb-revision: cannot read $f" >&2; exit 2; }
field() { awk -F= -v k="$1" '$1 == k { v = $2; gsub(/^"|"$/, "", v); print v; exit }' "$f"; }
id="$(field ID)"; ver="$(field VERSION_ID)"; base="${DEB_REVISION_BASE:-1}"
case "$id" in
    debian) [[ "$ver" =~ ^[0-9]+$ ]] || { echo "pkg-deb-revision: Debian VERSION_ID '$ver'" >&2; exit 2; }
            printf '%s~deb%s\n' "$base" "$ver" ;;
    ubuntu) [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "pkg-deb-revision: Ubuntu VERSION_ID '$ver'" >&2; exit 2; }
            printf '%s~ubuntu%s\n' "$base" "$ver" ;;
    *) echo "pkg-deb-revision: distribution '$id' is not one this names" >&2; exit 2 ;;
esac
