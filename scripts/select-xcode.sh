#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# select-xcode.sh -- select the Xcode a repository's .xcode-version names (the
# one place that version is stated) and its macOS SDK, explicitly. Left to the
# defaults, xcrun can pick the Command Line Tools SDK of a newer macOS, whose
# .tbd files that Xcode's linker cannot parse; and a runner image changes its
# default Xcode on its own schedule.
#
# An Xcode is chosen by the version `xcodebuild -version` reports, never by its
# bundle name, and DEVELOPER_DIR is its resolved path: an image may install
# Xcode_27.app and point Xcode_27.0.app at it, and xcrun reports the SDK by
# the resolved path. The SDK must lie inside that Xcode.
#
# In Actions (GITHUB_ENV set) it appends DEVELOPER_DIR and SDKROOT to
# $GITHUB_ENV; elsewhere it prints them for
#   eval "$(select-xcode.sh --root <checkout>)"
#
# Usage: select-xcode.sh [--root DIR]     (default: the working directory)
# SELECT_XCODE_APPLICATIONS replaces /Applications (for the self-test).
#
# Runs under the bash macOS ships (3.2): the action calls it with /bin/bash,
# and the self-test runs it there.
#
# Exit codes: 0 selected; 1 refused (empty .xcode-version, no installed Xcode
# reports that version, its SDK is elsewhere); 2 usage, no root, no
# .xcode-version.
set -euo pipefail

usage() { echo "usage: select-xcode.sh [--root DIR]" >&2; exit 2; }
root=.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) [ "$#" -ge 2 ] || usage; root="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -d "$root" ] || { echo "select-xcode: $root is not a directory" >&2; exit 2; }
[ -f "$root/.xcode-version" ] || { echo "select-xcode: no .xcode-version in $root" >&2; exit 2; }
want="$(tr -d '[:space:]' < "$root/.xcode-version")"
[ -n "$want" ] || { echo "select-xcode: $root/.xcode-version is empty" >&2; exit 1; }

apps="${SELECT_XCODE_APPLICATIONS:-/Applications}"
found=""
seen=""
for app in "$apps/Xcode_$want.app" "$apps/Xcode.app" "$apps"/Xcode*.app; do
    [ -d "$app/Contents/Developer" ] || continue
    v="$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2>/dev/null | sed -n 's/^Xcode //p')" || v=""
    seen="$seen ${app##*/}=$v"
    if [ "$v" = "$want" ]; then found="$(cd -P "$app/Contents/Developer" && pwd)"; break; fi
done
[ -n "$found" ] || { echo "select-xcode: no Xcode $want installed (found:${seen:- none})" >&2; exit 1; }

sdk="$(DEVELOPER_DIR="$found" xcrun --sdk macosx --show-sdk-path)"
case "$sdk" in "$found"/*) ;; *) echo "select-xcode: the SDK $sdk is not inside $found" >&2; exit 1 ;; esac

if [ -n "${GITHUB_ENV:-}" ]; then
    { echo "DEVELOPER_DIR=$found"; echo "SDKROOT=$sdk"; } >> "$GITHUB_ENV"
else
    printf 'export DEVELOPER_DIR=%q\nexport SDKROOT=%q\n' "$found" "$sdk"
fi
echo "select-xcode: Xcode $want at $found, SDK $sdk" >&2
