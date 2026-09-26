#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-deps.sh -- the upstream closure a package build needs, from deps.lock.
#
# Usage:
#   pkg-deps.sh closure [--root DIR] [--ref NAME=REF]...
#       Print "<name> <url> <commit40>" for every upstream the
#       consumer at DIR builds against, TRANSITIVELY (a consumer's lock lists
#       only what it builds from source; LibreCelik locks LibreAgent, whose own
#       lock at that commit brings LibreMiddleware), dependencies before the
#       repositories that need them. --ref replaces a locked commit with the
#       current commit of REF at the same URL (a manual build against a branch).
#   pkg-deps.sh checkout <url> <commit40> <dest>
#       A clean tree of that commit, submodules included, at DEST.
#
# deps.lock (in the consumer root) has one row per upstream:
#   <name>  <url>  <commit40>
# (a row with a fourth column is the old format, and a finding).
# No deps.lock means no upstream (the bottom of the stack).
#
# Root: --root, else REPO_ROOT, else GITHUB_WORKSPACE, else the git top level
# of the working directory -- never this script's own location.
#
# Exit codes: 0 answered, 1 a finding (malformed lock, the same upstream
# locked at two commits in one closure, a cycle), 2 cannot judge (no root,
# an upstream that cannot be fetched).
set -uo pipefail

die() { echo "pkg-deps: $2" >&2; exit "$1"; }
CACHE="${PKG_DEPS_CACHE:-}"

cmd="${1:-}"; shift || true

# parse_lock FILE LABEL -> "name url sha" lines on stdout; exit 1 on form
parse_lock() {
    awk -v label="$2" '
        /^[[:space:]]*(#|$)/ { next }
        {
            if (NF == 4) { printf "pkg-deps: %s:%d: %s has a fourth column (%s) -- the lock is <name> <url> <commit40>; drop column 4\n", label, NR, $1, $4 > "/dev/stderr"; bad = 1; next }
            if (NF != 3) { printf "pkg-deps: %s:%d: want <name> <url> <commit40>\n", label, NR > "/dev/stderr"; bad = 1; next }
            if ($3 !~ /^[0-9a-f]{40}$/) { printf "pkg-deps: %s:%d: %s commit is not 40 hex\n", label, NR, $1 > "/dev/stderr"; bad = 1; next }
            print $1, $2, $3
        }
        END { exit bad }
    ' "$1"
}

gitdir_for() {  # gitdir_for URL -> a bare cache repository for URL (created)
    local key
    key="$(printf '%s' "$1" | sha256sum | cut -c1-16)"
    printf '%s/%s.git\n' "$CACHE" "$key"
}

# lock_at URL SHA -> that commit's deps.lock on stdout ("" when it has none)
lock_at() {
    local g
    g="$(gitdir_for "$1")"
    [ -d "$g" ] || git init -q --bare "$g" || return 2
    if ! git -C "$g" cat-file -e "$2^{commit}" 2>/dev/null; then
        git -C "$g" fetch -q --depth 1 "$1" "$2" 2>/dev/null \
            || git -C "$g" fetch -q "$1" 2>/dev/null || return 2
        git -C "$g" cat-file -e "$2^{commit}" 2>/dev/null || return 2
    fi
    git -C "$g" show "$2:deps.lock" 2>/dev/null || true
}

resolve_ref() {  # resolve_ref URL REF -> commit40
    local sha
    [[ "$2" =~ ^[0-9a-f]{40}$ ]] && { printf '%s\n' "$2"; return 0; }
    sha="$(git ls-remote "$1" "$2" "refs/heads/$2" "refs/tags/$2^{}" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
    printf '%s\n' "$sha"
}

cmd_closure() {
    local root=""
    local -A over=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --root) root="$2"; shift 2 ;;
            --ref) [[ "$2" == *=* ]] || die 2 "--ref wants NAME=REF"; over["${2%%=*}"]="${2#*=}"; shift 2 ;;
            *) die 2 "closure: unknown argument $1" ;;
        esac
    done
    [ -n "$root" ] || root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
    [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || die 2 "no root: pass --root or set REPO_ROOT"
    [ -d "$root" ] || die 2 "root $root is not a directory"
    [ -f "$root/deps.lock" ] || return 0

    local own=0
    if [ -z "$CACHE" ]; then CACHE="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-deps.XXXXXX")" || die 2 "no temp dir"; own=1; fi
    mkdir -p "$CACHE"

    local -A sha=() url=() state=()
    local order=() rows name u s
    # Depth-first post-order over the locks; state: 1 visiting, 2 done.
    visit() {  # visit NAME
        local n="$1" r nn uu ss
        [ "${state[$n]:-0}" = 2 ] && return 0
        [ "${state[$n]:-0}" = 1 ] && { echo "pkg-deps: cycle through $n" >&2; return 1; }
        state[$n]=1
        r="$(lock_at "${url[$n]}" "${sha[$n]}")" || { echo "pkg-deps: cannot fetch $n ${sha[$n]} from ${url[$n]}" >&2; return 2; }
        if [ -n "$r" ]; then
            r="$(printf '%s\n' "$r" | parse_lock /dev/stdin "$n@${sha[$n]:0:12}:deps.lock")" || return 1
            while read -r nn uu ss; do
                [ -n "$nn" ] || continue
                add "$nn" "$uu" "$ss" "$n@${sha[$n]:0:12}" || return $?
                visit "$nn" || return $?
            done <<<"$r"
        fi
        state[$n]=2
        order+=("$n")
    }
    add() {  # add NAME URL SHA FROM
        local s2="$3"
        if [ -n "${over[$1]+x}" ]; then
            s2="${ovsha[$1]:-}"
            if [ -z "$s2" ]; then
                s2="$(resolve_ref "$2" "${over[$1]}")" || { echo "pkg-deps: cannot resolve $1 ref ${over[$1]} at $2" >&2; return 2; }
                ovsha[$1]="$s2"
            fi
        fi
        if [ -n "${sha[$1]+x}" ] && [ "${sha[$1]}" != "$s2" ]; then
            echo "pkg-deps: $1 is locked at ${sha[$1]:0:12} and at ${s2:0:12} (from $4) -- one closure, one commit" >&2
            return 1
        fi
        sha[$1]="$s2"; url[$1]="$2"
    }
    local -A ovsha=()
    rows="$(parse_lock "$root/deps.lock" deps.lock)" || { [ "$own" = 1 ] && rm -rf "$CACHE"; return 1; }
    local rc=0
    while read -r name u s; do
        [ -n "$name" ] || continue
        add "$name" "$u" "$s" deps.lock || { rc=$?; break; }
        visit "$name" || { rc=$?; break; }
    done <<<"$rows"
    [ "$own" = 1 ] && rm -rf "$CACHE"
    [ "$rc" = 0 ] || return "$rc"
    for name in "${order[@]}"; do
        printf '%s %s %s\n' "$name" "${url[$name]}" "${sha[$name]}"
    done
}

cmd_checkout() {
    [ $# -eq 3 ] || die 2 "usage: checkout <url> <commit40> <dest>"
    local u="$1" s="$2" d="$3"
    [[ "$s" =~ ^[0-9a-f]{40}$ ]] || die 1 "checkout: $s is not a 40-hex commit"
    [ ! -e "$d" ] || [ -z "$(ls -A "$d")" ] || die 2 "checkout: $d exists and is not empty"
    mkdir -p "$d" || die 2 "checkout: cannot create $d"
    git -C "$d" init -q || die 2 "checkout: cannot init $d"
    git -C "$d" fetch -q --depth 1 "$u" "$s" 2>/dev/null || git -C "$d" fetch -q "$u" \
        || die 2 "checkout: cannot fetch $s from $u"
    git -C "$d" -c advice.detachedHead=false checkout -q "$s" || die 2 "checkout: $s is not in $u"
    git -C "$d" submodule -q update --init --recursive || die 2 "checkout: submodules of $s"
    [ "$(git -C "$d" rev-parse HEAD)" = "$s" ] || die 1 "checkout: HEAD is not $s"
    echo "pkg-deps: $u at $s in $d"
}

case "$cmd" in
    closure) cmd_closure "$@" ;;
    checkout) cmd_checkout "$@" ;;
    *) die 2 "usage: pkg-deps.sh closure [--root DIR] [--ref NAME=REF]... | checkout <url> <sha> <dest>" ;;
esac
