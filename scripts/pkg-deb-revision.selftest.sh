#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Self-test for pkg-deb-revision.sh: the revision names the distribution the
# package was built on, so two builds of one version never share a Version.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-deb-revision.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-deb-rev-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
cases=0; red=0; fail=0
expect() {  # expect <name> <want-rc> <want-out> <os-release body> [base]
    cases=$((cases + 1)); printf '%s\n' "$4" >"$work/os"
    out="$(DEB_REVISION_BASE="${5:-}" "$tool" "$work/os" 2>/dev/null)"; rc=$?
    if [ "$rc" = "$2" ] && [ "$out" = "$3" ]; then echo "ok   $1"; [ "$rc" != 0 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2 '$3', got rc=$rc '$out'"; fail=1; fi
}
expect "Debian 13"                       0 "1~deb13"       $'ID=debian\nVERSION_ID="13"\nVERSION_CODENAME=trixie'
expect "Ubuntu 26.04"                    0 "1~ubuntu26.04" $'ID=ubuntu\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute'
expect "base from the caller"            0 "3~deb13"       $'ID=debian\nVERSION_ID="13"' 3
expect "derivative is not guessed"       2 ""              $'ID=linuxmint\nID_LIKE=ubuntu\nVERSION_ID="22"'
expect "Debian without VERSION_ID (sid)" 2 ""              $'ID=debian\nVERSION_CODENAME=forky'
expect "Ubuntu VERSION_ID without dot"   2 ""              $'ID=ubuntu\nVERSION_ID="26"'
cases=$((cases + 1)); "$tool" "$work/missing" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then echo "ok   unreadable file is cannot-judge"; red=$((red + 1)); else echo "FAIL unreadable: rc=$rc"; fail=1; fi
echo "selftest: $cases cases, $red red-proved"
exit "$fail"
