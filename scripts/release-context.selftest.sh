#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC1007,SC2010,SC2012,SC2015,SC2016,SC2028,SC2181  # fixture text is literal on purpose; A && B || C report lines
# Self-test for release-context.sh: which mode a ref allows, which version a run
# is about, and the one pre-release predicate.
set -u

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/release-context.sh"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/var/tmp}/release-context-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

cases=0; red=0; fails=0
check() {  # check <name> <want-rc> <needle|-> -- <command...>
    local name=$1 want=$2 needle=$3 out got
    shift 4
    cases=$((cases + 1))
    [ "$want" != 0 ] && red=$((red + 1))
    out="$("$@" 2>&1)"; got=$?
    if [ "$got" != "$want" ]; then
        printf 'FAIL  %s: rc=%s, want %s\n' "$name" "$got" "$want"
        printf '%s\n' "$out" | sed 's/^/  | /'
        fails=$((fails + 1)); return
    fi
    if [ "$needle" != - ] && ! printf '%s\n' "$out" | grep -qxF -- "$needle" \
            && ! printf '%s' "$out" | grep -qF -- "$needle"; then
        printf 'FAIL  %s: rc=%s as wanted, but the output does not carry "%s"\n' "$name" "$got" "$needle"
        printf '%s\n' "$out" | sed 's/^/  | /'
        fails=$((fails + 1)); return
    fi
    printf 'ok    %s (rc=%s)\n' "$name" "$got"
}

tree="$work/tree"; mkdir -p "$tree"; printf '5.0.0\n' > "$tree/VERSION"
decoy="$work/decoy"; mkdir -p "$decoy"; printf '9.9.9\n' > "$decoy/VERSION"
ctx() {  # ctx <ref> <mode>
    env -u GITHUB_WORKSPACE REPO_ROOT="$tree" GITHUB_REF="$1" bash "$subject" "$2"
}

check "M1 publish on a tag" 0 "version=5.0.0" -- ctx refs/tags/5.0.0 publish
check "M2 publish on a branch is refused" 1 "only a tag ref can be published" -- ctx refs/heads/ci/5.0 publish
check "M3 rehearse on a branch reads VERSION" 0 "version=5.0.0" -- ctx refs/heads/main rehearse
check "M4 rehearse on a tag rehearses that tag" 0 "tag=5.0.1" -- ctx refs/tags/5.0.1 rehearse
check "M5 an unknown mode" 2 "neither rehearse nor publish" -- ctx refs/tags/5.0.0 draft
check "M6 no GITHUB_REF" 2 "GITHUB_REF" -- env -u GITHUB_REF REPO_ROOT="$tree" bash "$subject" publish
check "M7 a leading v is stripped" 0 "version=5.0.0" -- ctx refs/tags/v5.0.0 publish

check "V1 -rc1 is a pre-release" 0 "is_prerelease=true" -- ctx refs/tags/5.0.0-rc1 publish
check "V2 a final tag is not" 0 "is_prerelease=false" -- ctx refs/tags/5.0.0 publish
check "V3 an unmarked suffix is refused, not published as stable" 1 "would publish as a stable release" -- \
    ctx refs/tags/5.0.0-final publish
check "V4 a dotted suffix is not a version" 1 "not X.Y.Z" -- ctx refs/tags/5.0.0.hotfix publish
check "V5 a two-part version" 1 "not X.Y.Z" -- ctx refs/tags/5.0 publish
printf 'unreleased\n' > "$work/bad"; mkdir -p "$work/badtree"; cp "$work/bad" "$work/badtree/VERSION"
check "V6 a VERSION that is not a version" 1 "not X.Y.Z" -- \
    env REPO_ROOT="$work/badtree" GITHUB_REF=refs/heads/main bash "$subject" rehearse

check "R1 rehearse on a branch with no VERSION" 2 "no VERSION" -- \
    env REPO_ROOT="$work/nowhere" GITHUB_REF=refs/heads/main bash "$subject" rehearse
check "R2 REPO_ROOT wins over a decoy workspace, from /" 0 "version=5.0.0" -- \
    env GITHUB_WORKSPACE="$decoy" REPO_ROOT="$tree" GITHUB_REF=refs/heads/main \
    bash -c 'cd / && bash "$1" rehearse' _ "$subject"

if [ "$fails" -eq 0 ]; then
    echo "release-context selftest: all cases passed"
else
    echo "release-context selftest: $fails case(s) failed"
fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fails" -eq 0 ]
