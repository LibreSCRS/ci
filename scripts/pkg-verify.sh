#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-verify.sh -- install a whole package stack in a CLEAN container of the
# slug's image and judge it: pkg-verify-inside.sh does the installing and the
# smoke checks, pkg-lint-accept.py judges lintian / rpmlint against
# lint-accepted/.
#
# Usage: pkg-verify.sh --slug S --packages DIR [--packages DIR]...
#                      [--lint DIR]... [--report DIR] [--accepted DIR]
#                      [--hook FILE --name REPO]
#
# --lint limits lintian / rpmlint to the packages under those directories
# (the consumer's own); the other packages are installed for the smoke checks
# and linted in the repository that builds them. Without --lint every package
# is linted (the whole-stack run). A --lint directory with no package of the
# family cannot be judged.
#
# --hook runs the consumer's own installed-state assertions LAST, inside the
# same clean container (pkg-verify-inside.sh S10), instead of in a container
# of their own. The hook sees <DIR>/<REPO>/<family>/ at /pkg and every other
# <DIR>/<Repository>/<family>/ at /pkg-<Repository> -- the layout pkg-build
# leaves -- plus FAMILY and PKG_MANAGER. A hook with no <DIR>/<REPO>/<family>
# to show it cannot be judged.
#
# Each DIR holds .deb / .rpm files (any names: build names or release asset
# names). --report keeps the raw logs (default: a temporary directory that is
# removed); --accepted defaults to this repository's lint-accepted/.
# Environment: PKG_DOCKER, PKG_DOCKER_NETWORK as pkg-gate.sh.
#
# Exit codes: 0 the stack is green, 1 a check or the lint judgement failed,
# 2 cannot judge (unknown slug, no docker, no package, lint not judgeable).
set -uo pipefail
here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)" || exit 2

slug="" report="" accepted="$here/../lint-accepted" hook="" name=""
dirs=() lintdirs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --slug) slug="$2"; shift 2 ;;
        --packages) dirs+=("$2"); shift 2 ;;
        --lint) lintdirs+=("$2"); shift 2 ;;
        --report) report="$2"; shift 2 ;;
        --accepted) accepted="$2"; shift 2 ;;
        --hook) hook="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        *) echo "pkg-verify: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$slug" ] && [ "${#dirs[@]}" -gt 0 ] || { echo "usage: pkg-verify.sh --slug S --packages DIR..." >&2; exit 2; }
DOCKER="${PKG_DOCKER:-docker}"
command -v "$DOCKER" >/dev/null 2>&1 || { echo "pkg-verify: $DOCKER is not on PATH -- cannot judge" >&2; exit 2; }
NET=()
[ -z "${PKG_DOCKER_NETWORK:-}" ] || NET=(--network "$PKG_DOCKER_NETWORK")
image="$("$here/pkg-images" get "$slug")" || exit 2
manager="$("$here/pkg-images" manager "$slug")" || exit 2
family="$("$here/pkg-images" family "$slug")" || exit 2

mounts=()
i=0
for d in "${dirs[@]}"; do
    [ -d "$d" ] || { echo "pkg-verify: $d is not a directory" >&2; exit 2; }
    d="$(cd "$d" && pwd)"
    mounts+=(-v "$d:/pkgs/$i:ro"); i=$((i + 1))
done
hookargs=()
if [ -n "$hook" ]; then
    [ -f "$hook" ] || { echo "pkg-verify: hook $hook is not a file -- cannot judge" >&2; exit 2; }
    [ -n "$name" ] || { echo "pkg-verify: --hook needs --name" >&2; exit 2; }
    hookargs=(-v "$(cd "$(dirname "$hook")" && pwd)/$(basename "$hook"):/hook.sh:ro" -e PKG_VERIFY_HOOK=/hook.sh)
    ownpkg=0
    for d in "${dirs[@]}"; do
        for sub in "$d"/*/"$family"; do
            [ -d "$sub" ] || continue
            sub="$(cd "$sub" && pwd)"
            r="$(basename "$(dirname "$sub")")"
            if [ "$r" = "$name" ]; then hookargs+=(-v "$sub:/pkg:ro"); ownpkg=1
            else hookargs+=(-v "$sub:/pkg-$r:ro"); fi
        done
    done
    [ "$ownpkg" = 1 ] || { echo "pkg-verify: no <dir>/$name/$family under ${dirs[*]} for the hook -- cannot judge" >&2; exit 2; }
fi
n="$(find "${dirs[@]}" -type f -name "*.$family" | wc -l)"
[ "$n" -gt 0 ] || { echo "pkg-verify: no .$family package under ${dirs[*]} -- cannot judge" >&2; exit 2; }

own=0
if [ -z "$report" ]; then report="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-verify.XXXXXX")" || exit 2; own=1; fi
mkdir -p "$report" && report="$(cd "$report" && pwd)"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { [ "$own" = 0 ] || rm -rf "$report" 2>/dev/null || "$DOCKER" run --rm -v "$report:/r" "$image" rm -rf /r/. 2>/dev/null; }
trap 'cleanup' EXIT

rm -f "$report/lint-files.txt"
if [ "${#lintdirs[@]}" -gt 0 ]; then
    for d in "${lintdirs[@]}"; do
        [ -d "$d" ] || { echo "pkg-verify: --lint $d is not a directory -- cannot judge" >&2; exit 2; }
    done
    find "${lintdirs[@]}" -type f -name "*.$family" -printf '%f\n' | sort -u >"$report/lint-files.txt"
    [ -s "$report/lint-files.txt" ] || { echo "pkg-verify: no .$family package under --lint ${lintdirs[*]} -- cannot judge" >&2; exit 2; }
    echo "   lint scope: $(wc -l <"$report/lint-files.txt") package(s) under ${lintdirs[*]}"
fi
echo "== pkg-verify $slug ($manager): $n package(s) from ${#dirs[@]} director(ies)"
"$DOCKER" run --rm "${NET[@]}" "${mounts[@]}" -v "$here:/ci-scripts:ro" -v "$report:/report" "${hookargs[@]}" \
    -e PKG_MANAGER="$manager" -e PKG_SLUG="$slug" "$image" bash /ci-scripts/pkg-verify-inside.sh
irc=$?

linted="$(paste -sd, "$report/linted.txt" 2>/dev/null)"
largs=(--slug "$slug" --accepted "$accepted" --linted "$linted")
[ ! -f "$report/lintian.txt" ] || largs+=(--lintian "$report/lintian.txt")
[ ! -f "$report/rpmlint.txt" ] || largs+=(--rpmlint "$report/rpmlint.txt")
python3 "$here/pkg-lint-accept.py" "${largs[@]}"
lrc=$?

echo "== pkg-verify $slug: smoke rc=$irc, lint rc=$lrc"
[ "$irc" -eq 1 ] || [ "$lrc" -eq 1 ] && exit 1
[ "$irc" -eq 0 ] && [ "$lrc" -eq 0 ] && exit 0
exit 2
