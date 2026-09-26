#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-changelog-debian.sh: headlines whole and wrapped under 80
# columns, the project maintainer, only the topmost section, and a headline
# naming a source path or a process word is red.
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-changelog-debian.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-changelog-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
unset GITHUB_WORKSPACE

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; sed 's/^/  | /' "$work/out" "$work/cl" 2>/dev/null; fail=1; fi
}
LONG="Dual-interface readers keep the contact slot powered while a card sits in it, so a contactless probe of the same reader no longer resets the session the signing flow is using right now."
mk() {  # mk <changelog-body> [version]
    rm -rf "$work/r"; mkdir -p "$work/r"
    printf '%s\n' "${2:-5.0.0}" >"$work/r/VERSION"
    printf '%s\n' "$1" >"$work/r/CHANGELOG.md"
}
gen() { REPO_ROOT="$work/r" SOURCE_DATE_EPOCH="${EPOCH:-0}" "$tool" librescrs-x "$work/cl" >"$work/out" 2>&1; }

mk "# Changelog

## [Unreleased] — 5.0.0

### Added

- **Debian and RPM packages, built by the project.** Long prose follows here
  and continues on a second line that must never appear.
- **$LONG**
  More prose.
- A bullet with no bold lead contributes nothing.

### Fixed

- **A card could set a PIN length the encoding did not carry.**

## [4.2.0] — 2026-05-29

- **An older headline that must not appear.**"
gen; rc=$?
grep -qx '  \* New upstream release 5.0.0.' "$work/cl"; up=$?
grep -qx '  \* Debian and RPM packages, built by the project.' "$work/cl"; h1=$?
grep -qx '  \* A card could set a PIN length the encoding did not carry.' "$work/cl"; h3=$?
expect "headlines of the topmost section, whole" "0 0 0 0" "$rc $up $h1 $h3"
awk 'length > 80 { bad = 1 } END { exit bad }' "$work/cl"; w=$?
joined="$(awk '/Dual-interface/{on=1} on && /^    / {sub(/^    /,""); printf " %s", $0; next} on && !/^    /{if (s) exit} on{sub(/^  \* /,""); printf "%s", $0; s=1}' "$work/cl")"
[ "$joined" = "$LONG" ]; whole=$?
expect "a long headline wraps under 80 columns and loses no word" "0 0" "$w $whole"
! grep -q 'no bold lead\|prose\|older headline\|second line' "$work/cl"; expect "prose, unbolded bullets and older sections stay out" 0 $?
grep -qx ' -- LibreSCRS <librescrs@proton.me>  Thu, 01 Jan 1970 00:00:00 +0000' "$work/cl"; expect "maintainer and a date whose weekday is computed" 0 $?
head -n 1 "$work/cl" | grep -qx 'librescrs-x (5.0.0-1) unstable; urgency=medium'; expect "version and revision from VERSION" 0 $?

mk "## 5.0.0
- **Removed \`src/utils/utils.h\`, a header with one macro.**"
gen; expect "a source path in a headline is red" 1 $?
mk "## 5.0.0
- **The settings importer (settingsimport.cpp) is gone.**"
gen; expect "a C++ file in a headline is red" 1 $?
mk "## 5.0.0
- **Wave 6 review findings addressed.**"
gen; expect "a process word in a headline is red" 1 $?
mk "## 5.0.0
- **\`tools/migrate-3x-to-4.0.sh\` removed.**"
gen; expect "a user-facing tool script is not internal" 0 $?
mk "## 5.0.0
- plain bullet only"
gen; rc=$?
[ "$(grep -c '^  \* ' "$work/cl")" -eq 1 ]; expect "no headline still yields a valid entry" "0 0" "$rc $?"
mk "## 5.0.0
- **x.**" "five"
gen; expect "a VERSION that is not a version is red" 1 $?
mk "## 5.0.0"; rm "$work/r/VERSION"
gen; expect "no VERSION cannot be judged" 2 $?
( cd "$work" && env -u REPO_ROOT "$tool" librescrs-x "$work/cl" >"$work/out" 2>&1 ); expect "no root outside a checkout cannot be judged" 2 $?

[ "$fail" -eq 0 ] || { echo "pkg-changelog-debian.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
