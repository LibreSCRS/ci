#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# release-context.sh <mode> [--want-version V] [--want-prerelease true|false]
# -- what a release run is allowed to do, and which version it is about,
# decided once for every job of the run.
#
#   mode      rehearse | publish. `publish` is only legal on a tag ref: a
#             branch carries no signed tag, and a release created from one
#             would be a release of nothing anyone signed. `rehearse` is legal
#             anywhere, and on a tag ref it rehearses THAT tag.
#   version   the tag without a leading v on a tag ref; the first line of the
#             consumer's VERSION file otherwise. Either way it has to be
#             X.Y.Z or X.Y.Z-<pre-release>: the tag filter accepts an
#             arbitrary suffix, and a tag like 5.0.0.hotfix or 5.0.0-final used
#             to skip the lockstep AND publish as a stable release.
#   is_prerelease
#             ONE predicate (-rc, -beta, -alpha, -pre), used by the lockstep
#             exemption and by the publish flag alike, so the two cannot drift.
#             Any other suffix is refused rather than guessed at.
#
# A later job passes what the preflight job told it with --want-version and
# --want-prerelease; a value that is not what this derives is refused. A
# composite action does not enforce `required: true`, so a caller that never
# wired an input hands over an empty string -- for is_prerelease that would
# publish a pre-release as the latest stable release. Empty is refused like
# any other disagreement.
#
# Prints key=value lines on stdout (mode, ref, tag, version, is_prerelease);
# the composite actions append them to $GITHUB_OUTPUT. Reads GITHUB_REF and
# the consumer tree from REPO_ROOT (default $GITHUB_WORKSPACE, then the git
# toplevel of the current directory) -- never this script's own location.
#
# Exit: 0 the run may proceed - 1 it may not (publish on a branch, a malformed
#       or unmarked-suffix version, a --want-* that disagrees) - 2 cannot judge
#       (no ref, no VERSION, an unknown mode or option).
set -uo pipefail

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "FATAL: needs bash >= 4 -- cannot judge" >&2; exit 2; }
usage="usage: release-context.sh <rehearse|publish> [--want-version V] [--want-prerelease true|false]"
[ "$#" -ge 1 ] || { echo "FATAL: $usage" >&2; exit 2; }
mode=$1; shift
want_version=""; want_pre=""; check_version=0; check_pre=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --want-version) [ "$#" -ge 2 ] || { echo "FATAL: $usage" >&2; exit 2; }
                        want_version=$2; check_version=1; shift 2 ;;
        --want-prerelease) [ "$#" -ge 2 ] || { echo "FATAL: $usage" >&2; exit 2; }
                        want_pre=$2; check_pre=1; shift 2 ;;
        *) echo "FATAL: unknown argument '$1' -- $usage" >&2; exit 2 ;;
    esac
done
case "$mode" in
    rehearse|publish) ;;
    *) echo "FATAL: mode '$mode' is neither rehearse nor publish -- cannot judge" >&2; exit 2 ;;
esac

ref="${GITHUB_REF:-}"
[ -n "$ref" ] || { echo "FATAL: GITHUB_REF is not set -- cannot tell a tag from a branch" >&2; exit 2; }

tag=""
case "$ref" in
    refs/tags/*) tag="${ref#refs/tags/}" ;;
esac

if [ "$mode" = publish ] && [ -z "$tag" ]; then
    echo "::error::mode=publish on $ref -- only a tag ref can be published; a branch can only be rehearsed"
    exit 1
fi

if [ -n "$tag" ]; then
    version="${tag#v}"
    source_of="tag $tag"
else
    root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
    [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
    [ -n "$root" ] && [ -f "$root/VERSION" ] \
        || { echo "FATAL: no VERSION file in the consumer tree '${root:-<unset>}' (set REPO_ROOT) -- cannot judge" >&2; exit 2; }
    version="$(head -n 1 "$root/VERSION" | tr -d '[:space:]')"
    version="${version#v}"
    source_of="$root/VERSION"
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    echo "::error::$source_of gives version '$version', which is not X.Y.Z or X.Y.Z-<pre-release>"
    exit 1
fi
case "$version" in
    *-rc*|*-beta*|*-alpha*|*-pre*) pre=true ;;
    *-*)
        echo "::error::$source_of gives version '$version' -- a suffix that is not -rc/-beta/-alpha/-pre would publish as a stable release"
        exit 1 ;;
    *) pre=false ;;
esac

if [ "$check_version" = 1 ] && [ "$want_version" != "$version" ]; then
    echo "::error::the preflight said version '$want_version', this job derives '$version' -- the jobs disagree about what is released"
    exit 1
fi
if [ "$check_pre" = 1 ]; then
    case "$want_pre" in
        true|false) ;;
        *) echo "::error::is_prerelease '$want_pre' is neither true nor false -- pass the preflight job's is_prerelease output"
           exit 1 ;;
    esac
    if [ "$want_pre" != "$pre" ]; then
        echo "::error::the preflight said is_prerelease=$want_pre, this job derives $pre for $version -- the jobs disagree about what is released"
        exit 1
    fi
fi

printf 'mode=%s\nref=%s\ntag=%s\nversion=%s\nis_prerelease=%s\n' "$mode" "$ref" "$tag" "$version" "$pre"
