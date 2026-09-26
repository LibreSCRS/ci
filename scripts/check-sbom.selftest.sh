#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# check-sbom.selftest.sh -- one publishable bill, and every way a bill can be
# worthless while still being a file a release job would sign.
set -u
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/check-sbom"
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is not on PATH" >&2; exit 2; }
work="$(mktemp -d "/var/tmp/check-sbom-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
fails=0 cases=0 red=0

expect() {  # expect <want-rc> <label> <file...>
    local want=$1 label=$2 got; shift 2
    cases=$((cases + 1))
    [ "$want" = 0 ] || red=$((red + 1))
    python3 "$subject" "$@" >"$work/out" 2>&1; got=$?
    if [ "$got" = "$want" ]; then echo "ok    $label (rc=$got)"
    else echo "FAIL  $label: want rc=$want, got rc=$got"; sed 's/^/  | /' "$work/out"; fails=1; fi
}

printf '%s' '{"bomFormat":"CycloneDX","components":[{"name":"openssl","version":"3"}]}' >"$work/good.json"
printf '%s' '{"bomFormat":"CycloneDX","components":[]}' >"$work/empty.json"
printf '%s' '{"bomFormat":"CycloneDX","components":[{"version":"3"}]}' >"$work/nameless.json"
printf '%s' '{"bomFormat":"SPDX","components":[{"name":"openssl"}]}' >"$work/wrongformat.json"
printf '%s' '{"bomFormat":"CycloneDX"}' >"$work/nolist.json"
printf '%s' '[1, 2]' >"$work/array.json"
printf '%s' 'not json at all' >"$work/broken.json"

expect 0 "a bill with a named component is publishable" "$work/good.json"
expect 1 "an empty component list is refused" "$work/empty.json"
expect 1 "a component with no name is refused" "$work/nameless.json"
expect 1 "a document that is not CycloneDX is refused" "$work/wrongformat.json"
expect 1 "a document with no components array is refused" "$work/nolist.json"
expect 1 "a JSON document that is not an object is refused" "$work/array.json"
expect 1 "an unparseable document is refused" "$work/broken.json"
expect 1 "a bill that never arrived is refused" "$work/absent.json"
expect 2 "no arguments is a usage error, not a pass"
expect 1 "one empty bill in a set fails the set" "$work/good.json" "$work/empty.json"

[ "$fails" = 0 ] || { echo "check-sbom selftest: FAILED"; exit 1; }
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
