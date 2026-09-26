#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-chain.sh -- build a consumer's packages for one slug, with its upstream
# packages obtained one of two ways, in the same job and without any token
# beyond the job's own GITHUB_TOKEN.
#
# Usage:
#   pkg-chain.sh build --slug S --art DIR --upstream source|release
#                [--version V] [--root DIR] [--name NAME] [--ref NAME=REF]...
#                [--dist DIR]
#   pkg-chain.sh fetch --repo OWNER/NAME --version V --pattern GLOB --into DIR
#
# build:
#   upstream=source   every upstream in the deps.lock closure is checked out at
#                     its locked commit (or at --ref) and built for the same
#                     slug, bottom up, before the consumer. An upstream already
#                     built from that commit under DIR is reused, so a chain of
#                     consumers sharing DIR builds the bottom once.
#   upstream=release  every upstream's `*.<slug>.<deb|rpm>` assets of release V
#                     are downloaded (public assets: `gh release download`).
#   Then the consumer is built by pkg-gate.sh, and with --dist its packages are
#   collected into DIST as `<package>.<slug>.<deb|rpm>` (pkg-collect.sh).
# fetch:
#   the release-mode download on its own: files matching GLOB of release V of
#   OWNER/NAME into DIR. Zero matches, or a debug package, is a refusal.
#
# Root / NAME as pkg-gate.sh. PKG_GH replaces `gh` for the self-test.
# Exit codes: 0 built, 1 a gate or a download refused, 2 cannot judge.
set -uo pipefail
here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)" || exit 2
GH="${PKG_GH:-gh}"

die() { echo "pkg-chain: $2" >&2; exit "$1"; }

fetch() {  # fetch REPO VERSION PATTERN INTO
    local repo="$1" ver="$2" pat="$3" into="$4" f n
    command -v "$GH" >/dev/null 2>&1 || { echo "pkg-chain: $GH is not on PATH" >&2; return 2; }
    mkdir -p "$into" || return 2
    if ! "$GH" release download "$ver" -R "$repo" -p "$pat" -D "$into" --clobber >"$into.log" 2>&1; then
        sed 's/^/  gh: /' "$into.log"
        if grep -q 'no assets match' "$into.log"; then
            echo "pkg-chain: release $ver of $repo has no asset matching '$pat'"; return 1
        fi
        echo "pkg-chain: cannot download from release $ver of $repo" >&2; return 2
    fi
    n=0
    for f in "$into"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            *-dbgsym_*|*.ddeb|*-debuginfo-*|*-debugsource-*)
                echo "pkg-chain: release $ver of $repo publishes a debug package: $(basename "$f")"; return 1 ;;
        esac
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || { echo "pkg-chain: nothing arrived from release $ver of $repo for '$pat'"; return 1; }
    echo "pkg-chain: $n file(s) from $repo $ver matching '$pat'"
    find "$into" -maxdepth 1 -type f -printf '  %f\n' | sort
}

cmd_fetch() {
    local repo="" ver="" pat="" into=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;; --version) ver="$2"; shift 2 ;;
            --pattern) pat="$2"; shift 2 ;; --into) into="$2"; shift 2 ;;
            *) die 2 "fetch: unknown argument $1" ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$ver" ] && [ -n "$pat" ] && [ -n "$into" ] || die 2 "fetch: --repo --version --pattern --into are required"
    fetch "$repo" "$ver" "$pat" "$into"
}

cmd_build() {
    local slug="" art="" mode="" ver="" root="" name="" dist=""
    local refs=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug) slug="$2"; shift 2 ;; --art) art="$2"; shift 2 ;;
            --upstream) mode="$2"; shift 2 ;; --version) ver="$2"; shift 2 ;;
            --root) root="$2"; shift 2 ;; --name) name="$2"; shift 2 ;;
            --ref) refs+=(--ref "$2"); shift 2 ;; --dist) dist="$2"; shift 2 ;;
            *) die 2 "build: unknown argument $1" ;;
        esac
    done
    [ -n "$slug" ] && [ -n "$art" ] || die 2 "build: --slug and --art are required"
    case "$mode" in
        source) ;;
        release) [ -n "$ver" ] || die 2 "build: upstream=release needs --version" ;;
        *) die 2 "build: --upstream must be source or release" ;;
    esac
    [ "$mode" = source ] || [ "${#refs[@]}" -eq 0 ] || die 2 "build: --ref only makes sense with upstream=source"
    [ -n "$root" ] || root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
    [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || die 2 "no root"
    root="$(cd "$root" && pwd)" || die 2 "root $root"
    [ -n "$name" ] || name="$(basename "$root")"
    local fam
    fam="$("$here/pkg-images" family "$slug")" || exit 2
    mkdir -p "$art" || die 2 "art $art"
    art="$(cd "$art" && pwd)" || die 2 "art $art"

    local rows rc up url sha _v repo
    rows="$("$here/pkg-deps.sh" closure --root "$root" "${refs[@]}")"; rc=$?
    [ "$rc" -eq 0 ] || { echo "pkg-chain: the upstream closure of $name cannot be built (rc=$rc)"; return "$rc"; }
    echo "== pkg-chain $name on $slug, upstream=$mode"
    [ -n "$rows" ] && printf '%s\n' "$rows" | sed 's/^/   upstream /' || echo "   no upstream"

    while read -r up url sha _v; do
        [ -n "$up" ] || continue
        if [ "$mode" = release ]; then
            repo="$(printf '%s\n' "$url" | sed -nE 's#^https://github\.com/([^/]+/[^/.]+)(\.git)?/?$#\1#p')"
            [ -n "$repo" ] || { echo "pkg-chain: $up url $url is not a github.com repository" >&2; return 2; }
            rm -rf "${art:?}/$slug/$up/$fam"
            fetch "$repo" "$ver" "*.$slug.$fam" "$art/$slug/$up/$fam" || return $?
            continue
        fi
        if [ "$(cat "$art/$slug/$up/.built-from" 2>/dev/null)" = "$sha" ] \
           && ls "$art/$slug/$up/$fam"/*."$fam" >/dev/null 2>&1; then
            echo "   $up ${sha:0:12}: already built for $slug under $art, reused"
            continue
        fi
        local co="$art/.work/checkout/$up-${sha:0:12}"
        rm -rf "$co"
        "$here/pkg-deps.sh" checkout "$url" "$sha" "$co" || return $?
        "$here/pkg-gate.sh" --slug "$slug" --art "$art" --root "$co" --name "$up" || return $?
    done <<<"$rows"

    "$here/pkg-gate.sh" --slug "$slug" --art "$art" --root "$root" --name "$name" || return $?
    if [ -n "$dist" ]; then
        "$here/pkg-collect.sh" "$slug" "$dist" "$art/$slug/$name/$fam" || return $?
    fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
    build) cmd_build "$@" ;;
    fetch) cmd_fetch "$@" ;;
    *) die 2 "usage: pkg-chain.sh build ... | fetch ..." ;;
esac
