#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Self-test for pkg-collect.sh: the slug lands in every asset name, and a debug
# package, a wrong-family package, a name collision or an empty set is refused
# with nothing copied.
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-collect.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-collect-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; fail=1; fi
}
fresh() { rm -rf "$work/in" "$work/in2" "$work/out"; mkdir -p "$work/in" "$work/in2"; }
touchall() { for f in "$@"; do printf 'x\n' >"$work/$f"; done; }

# green: deb set with a .changes beside it
fresh
touchall in/liblibrescrs5_5.0.0-1_amd64.deb in/librescrs-pkcs11-direct_5.0.0-1_all.deb in/x_5.0.0-1_amd64.changes
"$tool" debian13 "$work/out" "$work/in" >"$work/log" 2>&1; rc=$?
test -f "$work/out/liblibrescrs5_5.0.0-1_amd64.debian13.deb" -a -f "$work/out/librescrs-pkcs11-direct_5.0.0-1_all.debian13.deb"; named=$?
test "$(find "$work/out" -type f | wc -l)" -eq 2; only=$?
grep -q 'not published: .*x_5.0.0-1_amd64.changes' "$work/log"; listed=$?
expect "deb set collected with the slug, .changes listed not published" "0 0 0 0" "$rc $named $only $listed"

# green: rpm from two directories (two repositories) on an openSUSE slug
fresh
touchall in/librescrs-middleware-5.0.0-1.opensusetw.x86_64.rpm in2/librescrs-agent-5.0.0-1.opensusetw.x86_64.rpm
"$tool" opensusetw "$work/out" "$work/in" "$work/in2" >"$work/log" 2>&1; rc=$?
test -f "$work/out/librescrs-agent-5.0.0-1.opensusetw.x86_64.opensusetw.rpm"; expect "rpm from two directories" "0 0" "$rc $?"

red_case() {  # red_case <name> <slug> <files...>
    local name="$1" slug="$2"; shift 2
    fresh; touchall "$@"
    "$tool" "$slug" "$work/out" "$work/in" "$work/in2" >"$work/log" 2>&1; local rc=$?
    local copied=0; [ -d "$work/out" ] && copied=$(find "$work/out" -type f | wc -l)
    expect "$name (nothing copied: $copied)" "1 0" "$rc $copied"
}
red_case "Debian -dbgsym is refused" debian13 in/liblibrescrs5_5.0.0-1_amd64.deb in/liblibrescrs5-dbgsym_5.0.0-1_amd64.deb
red_case "Ubuntu .ddeb is refused" ubuntu2604 in/liblibrescrs5_5.0.0-1_amd64.deb in/liblibrescrs5-dbgsym_5.0.0-1_amd64.ddeb
red_case "Fedora -debuginfo is refused" fedora43 in/librescrs-middleware-5.0.0-1.fc43.x86_64.rpm in/librescrs-middleware-debuginfo-5.0.0-1.fc43.x86_64.rpm
red_case "Fedora -debugsource is refused" fedora44 in/librescrs-middleware-5.0.0-1.fc44.x86_64.rpm in/librescrs-middleware-debugsource-5.0.0-1.fc44.x86_64.rpm
red_case "an rpm on a deb slug is refused" debian13 in/liblibrescrs5_5.0.0-1_amd64.deb in/librescrs-middleware-5.0.0-1.fc43.x86_64.rpm
red_case "two inputs wanting one asset name are refused" debian13 in/a_1_all.deb in2/a_1_all.deb
red_case "an already-slugged file is refused" debian13 in/a_1_all.debian13.deb
red_case "an empty set is refused" fedora43

fresh; touchall in/a_1_all.deb
"$tool" nosuchslug "$work/out" "$work/in" >/dev/null 2>&1; expect "unknown slug cannot be judged" 2 $?

[ "$fail" -eq 0 ] || { echo "pkg-collect.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
