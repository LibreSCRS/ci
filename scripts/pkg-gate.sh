#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-gate.sh -- build ONE repository's packages for ONE distribution slug in
# that slug's container, and judge what they leave on a clean machine.
#
# Usage: pkg-gate.sh --slug <slug> --art <artefact-root> [--root DIR] [--name NAME]
#
#   G1  a packaging recipe exists, and names the project maintainer
#   G2  it builds, in the slug's container from images.lock, against the
#       upstream packages already under <art>/<slug>/<Upstream>/<family>
#   G3  the repository's own installed-state assertions pass in a fresh
#       container (packaging/ci/verify-installed.sh, when the repository has one)
#   G5  the build dependency the manifest tool needs is declared, consistently
#   (G4 -- one PKCS#11 provider -- is asserted by verify-installed.sh and, over
#   the whole stack, by pkg-verify.sh.)
#
# The packages land, under their build names, in <art>/<slug>/<NAME>/<family>/,
# which is also where the next repository up the stack finds them as upstream.
# `.built-from` beside them records the commit they were built from.
#
# Root: --root, else REPO_ROOT, else GITHUB_WORKSPACE, else the git top level
# of the working directory. NAME: --name, else the root's directory name.
# Upstreams: the first column of pkg-deps.sh closure over the root's deps.lock.
#
# Environment: PKG_DOCKER (default docker), PKG_DOCKER_NETWORK (docker run
# --network, default unset), PKG_JOBS (build parallelism, default 2).
#
# Exit codes: 0 every gate passed, 1 a gate failed, 2 cannot judge (unknown
# slug, no root, docker missing).
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail

here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)" || exit 2
MAINTAINER="LibreSCRS <librescrs@proton.me>"

SLUG="" ART="" ROOT="" NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slug) SLUG="$2"; shift 2 ;;
        --art)  ART="$2"; shift 2 ;;
        --root) ROOT="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        *) echo "pkg-gate: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$SLUG" ] && [ -n "$ART" ] || { echo "usage: pkg-gate.sh --slug <slug> --art <dir> [--root DIR] [--name NAME]" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "pkg-gate: no root" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)" || exit 2
[ -n "$NAME" ] || NAME="$(basename "$ROOT")"
DOCKER="${PKG_DOCKER:-docker}"
command -v "$DOCKER" >/dev/null 2>&1 || { echo "pkg-gate: $DOCKER is not on PATH -- cannot judge" >&2; exit 2; }
NET=()
[ -z "${PKG_DOCKER_NETWORK:-}" ] || NET=(--network "$PKG_DOCKER_NETWORK")

IMAGE="$("$here/pkg-images" get "$SLUG")" || exit 2
FAMILY="$("$here/pkg-images" family "$SLUG")" || exit 2
MANAGER="$("$here/pkg-images" manager "$SLUG")" || exit 2

mkdir -p "$ART" && ART="$(cd "$ART" && pwd)"
WORK="$ART/.work"
OUT="$ART/$SLUG/$NAME/$FAMILY"
SRC="$WORK/src/$SLUG/$NAME"
LOG="$ART/log"
mkdir -p "$LOG" "$WORK"

fail=0
note() { printf '%-6s %s\n' "$1" "$2"; }
check() { if [ "$2" -eq 0 ]; then note PASS "$1"; else note FAIL "$1"; fail=1; fi; }

# A container built these trees as root; an ordinary rm fails on them and the
# next build would reuse a stale artefact. Delete through a container.
purge() {
    case "$1" in "$ART"/*) : ;; *) echo "purge refused: $1" >&2; return 1 ;; esac
    mkdir -p "$(dirname "$1")" 2>/dev/null
    [ -e "$1" ] || return 0
    rm -rf "$1" 2>/dev/null || "$DOCKER" run --rm "${NET[@]}" -v "$(dirname "$1"):/w" "$IMAGE" rm -rf "/w/$(basename "$1")" >/dev/null 2>&1
    test ! -e "$1"
}

g5_repo() {   # -> DECLARED | MISSING | INCONSISTENT | NO_RECIPES
    local r="$1" recipes=0 hits=0 f need=0
    grep -rqs "manifest2header" "$r/CMakeLists.txt" "$r/tools" && need=1
    for f in "$r/packaging/debian/control" "$r"/packaging/rpm/*.spec "$r/packaging/arch/PKGBUILD"; do
        [ -f "$f" ] || continue
        recipes=$((recipes + 1))
        grep -q "jsonschema" "$f" && hits=$((hits + 1))
    done
    printf 'need=%s recipes=%s hits=%s ' "$need" "$recipes" "$hits"
    if [ "$recipes" -lt 2 ]; then echo NO_RECIPES; return 1; fi
    if [ "$need" -eq 1 ]; then
        if [ "$hits" -eq "$recipes" ]; then echo DECLARED; return 0; else echo MISSING; return 1; fi
    fi
    if [ "$hits" -eq 0 ] || [ "$hits" -eq "$recipes" ]; then echo DECLARED; return 0; fi
    echo INCONSISTENT; return 1
}

echo "== pkg-gate $NAME on $SLUG ($FAMILY, $MANAGER)"
echo "   image     $IMAGE"
echo "   artefacts $OUT"

# ── G1 ────────────────────────────────────────────────────────────────────
spec=""
if [ "$FAMILY" = deb ]; then
    test -f "$ROOT/packaging/debian/control" -a -f "$ROOT/packaging/debian/rules"
    check "G1 debian recipe present" $?
    grep -qxF "Maintainer: $MAINTAINER" "$ROOT/packaging/debian/control"
    check "G1 debian/control Maintainer is '$MAINTAINER'" $?
else
    spec="$(find "$ROOT/packaging/rpm" -maxdepth 1 -name '*.spec' 2>/dev/null | sort | head -n 1)"
    test -n "$spec"; check "G1 rpm recipe present" $?
    if [ -n "$spec" ]; then
        # Every %changelog entry header names the maintainer; an entry that
        # names anyone else is the stale address this check exists for.
        awk -v m="$MAINTAINER" '/^%changelog/{c=1; next} c && /^\* /{ n++; if (index($0, m) == 0) bad++ } END { exit !(n > 0 && bad == 0) }' "$spec"
        check "G1 rpm %changelog entries name '$MAINTAINER'" $?
    fi
fi

# ── upstreams ─────────────────────────────────────────────────────────────
ups="$("$here/pkg-deps.sh" closure --root "$ROOT")"
rc=$?
check "G2 upstream closure from deps.lock" $rc
[ "$rc" -eq 2 ] && exit 2
MOUNTS=() VMOUNTS=()
while read -r up _; do
    [ -n "$up" ] || continue
    updir="$ART/$SLUG/$up/$FAMILY"
    if ! ls "$updir"/*."$FAMILY" >/dev/null 2>&1; then
        note FAIL "G2 upstream packages for $up missing under $updir -- build $up first"
        fail=1; continue
    fi
    MOUNTS+=(-v "$updir:/upstream/$up:ro")
    VMOUNTS+=(-v "$updir:/pkg-$up:ro")
done <<<"$ups"

# ── G2 ────────────────────────────────────────────────────────────────────
# The work copy comes from the committed tree, never from the working tree, so
# an uncommitted fix cannot make a gate pass that will fail for anyone else.
purge "$SRC" || exit 2
mkdir -p "$SRC"
head_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
if [ -e "$ROOT/.gitmodules" ]; then
    git clone --quiet --recurse-submodules "$ROOT" "$SRC" >/dev/null 2>&1
    rc=$?
    rm -rf "$SRC/.git"
else
    git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$SRC"
    rc=$?
fi
check "G2a work copy from HEAD ${head_sha:0:12}" $rc
epoch="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)"

# A dependency the release tarball carries but the repository does not is
# placed before the container starts: a build that reaches the network is not
# a build of a package.
if [ -x "$ROOT/packaging/ci/prepare-source.sh" ]; then
    ( cd "$SRC" && bash "$ROOT/packaging/ci/prepare-source.sh" ) >"$LOG/prepare-$NAME-$SLUG.txt" 2>&1
    check "G2b source prepared (vendored fetch-time dependencies)" $?
fi

purge "$OUT" >/dev/null 2>&1
mkdir -p "$OUT"
BUILDLOG="$LOG/build-$NAME-$SLUG.txt"
start=$(date +%s)
"$DOCKER" run --rm "${NET[@]}" -v "$SRC:/s" -v "$OUT:/out" -v "$here:/ci-scripts:ro" "${MOUNTS[@]}" -w /s \
    -e PKG_MANAGER="$MANAGER" -e PKG_SLUG="$SLUG" -e PKG_JOBS="${PKG_JOBS:-2}" \
    -e PKG_OUT=/out -e PKG_UPSTREAM=/upstream -e REPO_ROOT=/s -e SOURCE_DATE_EPOCH="$epoch" \
    "$IMAGE" bash "/ci-scripts/pkg-build-$FAMILY.sh" >"$BUILDLOG" 2>&1
rc=$?
check "G2 build in $((($(date +%s) - start) / 60)) min ($BUILDLOG)" $rc
[ "$rc" -eq 0 ] || tail -n 30 "$BUILDLOG"

if [ -x "$ROOT/packaging/ci/extra-build-checks.sh" ] && [ "$rc" -eq 0 ]; then
    BUILDLOG="$BUILDLOG" SRC="$SRC" OUT="$OUT" FAMILY="$FAMILY" \
        bash "$ROOT/packaging/ci/extra-build-checks.sh"
    check "G2 repository-specific build assertions" $?
fi

if [ "$rc" -eq 0 ]; then
    n=$(find "$OUT" -maxdepth 1 -name "*.$FAMILY" | wc -l)
    test "$n" -gt 0; check "G2 built $n $FAMILY package(s)" $?
    find "$OUT" -maxdepth 1 -type f -printf '     %f\n' | sort
    printf '%s\n' "$head_sha" >"$ART/$SLUG/$NAME/.built-from"
fi

# ── G3 ────────────────────────────────────────────────────────────────────
# Building a package proves less than installing one. This runs in a container
# that never had a source tree.
if [ "$rc" -ne 0 ]; then
    note SKIP "G3 not run: the build failed, and asserting over a stale package is worse than not asserting"
    fail=1
elif [ -f "$ROOT/packaging/ci/verify-installed.sh" ]; then
    VLOG="$LOG/verify-$NAME-$SLUG.txt"
    "$DOCKER" run --rm "${NET[@]}" -v "$OUT:/pkg:ro" "${VMOUNTS[@]}" \
        -v "$ROOT/packaging/ci/verify-installed.sh:/verify.sh:ro" \
        -e FAMILY="$FAMILY" -e PKG_MANAGER="$MANAGER" -e PKG_SLUG="$SLUG" \
        "$IMAGE" bash /verify.sh >"$VLOG" 2>&1
    vrc=$?
    check "G3 installed-state assertions ($VLOG)" $vrc
    [ "$vrc" -eq 0 ] || tail -n 40 "$VLOG"
    grep -E '^(PASS|FAIL) ' "$VLOG" | sed 's/^/   /'
else
    note INFO "G3 $NAME carries no packaging/ci/verify-installed.sh; the stack is judged by pkg-verify.sh"
fi

# ── G5 ────────────────────────────────────────────────────────────────────
printf '%-6s %s ' INFO "G5 $NAME:"
g5_repo "$ROOT"
check "G5 jsonschema build dependency" $?

echo "== pkg-gate $NAME on $SLUG: $([ $fail -eq 0 ] && echo GREEN || echo RED)"
exit $fail
