#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-gate.sh with docker replaced by a stub that "builds" by
# writing package files into the /out mount: a stale maintainer, a failed
# build, a failed installed-state check, a missing upstream and an undeclared
# manifest dependency are each red; an unknown slug cannot be judged.
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-gate.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-gate-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$work"
unset REPO_ROOT GITHUB_WORKSPACE

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; tail -n 20 "$work/log" | sed 's/^/  | /'; fail=1; fi
}

# docker stub: `run` with -v SRC:DST mounts; the command after the image is
# `bash /ci-scripts/pkg-build-<fam>.sh` (write packages into /out),
# or `rm -rf /w/<x>` (purge).
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = run ] || exit 0; shift
declare -A m=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rm) shift ;;
    -v) IFS=: read -r a b _ <<<"$2"; m[$b]="$a"; shift 2 ;;
    -w|-e|--network) shift 2 ;;
    *) break ;;
  esac
done
img="$1"; shift
echo "$img $*" >>"$STUB_LOG"
case "$*" in
  "bash /ci-scripts/pkg-build-deb.sh")
    [ "${STUB_BUILD_RC:-0}" = 0 ] || exit "$STUB_BUILD_RC"
    printf 'deb\n' >"${m[/out]}/librescrs-x_5.0.0-1_amd64.deb"; exit 0 ;;
  "bash /ci-scripts/pkg-build-rpm.sh")
    [ "${STUB_BUILD_RC:-0}" = 0 ] || exit "$STUB_BUILD_RC"
    printf 'rpm\n' >"${m[/out]}/librescrs-x-5.0.0-1.fc43.x86_64.rpm"; exit 0 ;;
  rm\ -rf\ /w/*) rm -rf "${m[/w]}/${3#/w/}"; exit 0 ;;
esac
echo "docker stub: unexpected command: $*" >&2; exit 99
EOF
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH" PKG_DOCKER=docker STUB_LOG="$work/docker.log"

mkupstream() {  # a local upstream repository -> prints its commit
    local d="$work/up/LM"
    rm -rf "$d"; mkdir -p "$d"; git -C "$d" init -q -b main
    printf 'x\n' >"$d/f"; git -C "$d" add f; git -C "$d" commit -q -m c; git -C "$d" rev-parse HEAD
}
consumer() {  # consumer [maintainer] [spec-changelog-maintainer] [deps.lock] [jsonschema-in-deb:yes|no]
    local r="$work/repo"
    rm -rf "$r"; mkdir -p "$r/packaging/debian" "$r/packaging/rpm" "$r/packaging/arch" "$r/packaging/ci" "$r/tools"
    printf 'Source: librescrs-x\nMaintainer: %s\nBuild-Depends: %s\n' "${1:-LibreSCRS <librescrs@proton.me>}" \
        "$([ "${4:-yes}" = yes ] && echo python3-jsonschema || echo python3)" >"$r/packaging/debian/control"
    printf '#!/usr/bin/make -f\n' >"$r/packaging/debian/rules"
    printf 'Name: librescrs-x\nBuildRequires: python3-jsonschema\n%%changelog\n* Fri Sep 04 2026 %s - 5.0.0-1\n- x\n' \
        "${2:-LibreSCRS <librescrs@proton.me>}" >"$r/packaging/rpm/librescrs-x.spec"
    printf 'makedepends=(python-jsonschema)\n' >"$r/packaging/arch/PKGBUILD"
    printf 'manifest2header\n' >"$r/tools/manifest2header.py"
    # A legacy hook in the tree must not start a second container here.
    printf '#!/bin/sh\n' >"$r/packaging/ci/verify-installed.sh"
    [ -z "${3:-}" ] || printf '%s\n' "$3" >"$r/deps.lock"
    git -C "$r" init -q -b main && git -C "$r" add -A && git -C "$r" commit -q -m c
}
gate() {  # gate <slug> [env...]
    local slug="$1"; shift
    env "$@" "$tool" --slug "$slug" --art "$work/art" --root "$work/repo" --name LibreX >"$work/log" 2>&1
}

consumer; gate debian13; rc=$?
test -f "$work/art/debian13/LibreX/deb/librescrs-x_5.0.0-1_amd64.deb"; built=$?
test "$(cat "$work/art/debian13/LibreX/.built-from")" = "$(git -C "$work/repo" rev-parse HEAD)"; from=$?
n="$(grep -c ' bash /' "$work/docker.log")"
expect "deb gate green: package in <art>/<slug>/<Repo>/deb, commit recorded, one container" "0 0 0 1" "$rc $built $from $n"
grep -q 'docker.io/library/debian:13@sha256:[0-9a-f]\{64\} bash /ci-scripts/pkg-build-deb.sh' "$work/docker.log"
expect "the build runs in the slug's image by digest" 0 $?
gate fedora43; rc=$?
test -f "$work/art/fedora43/LibreX/rpm/librescrs-x-5.0.0-1.fc43.x86_64.rpm"; expect "rpm gate green" "0 0" "$rc $?"

consumer "LibreSCRS <packages@librescrs.org>"; gate debian13
expect "a stale Maintainer in debian/control is red" 1 $?
consumer "" "LibreSCRS <packages@librescrs.org>"; gate fedora43
expect "a stale maintainer in the spec %changelog is red" 1 $?
consumer; gate debian13 STUB_BUILD_RC=2
expect "a failed build is red" 1 $?
M="$(mkupstream)"
consumer "" "" "LM $work/up/LM $M"; gate debian13; rc=$?
grep -q 'upstream packages for LM missing' "$work/log"; expect "an upstream with no packages yet is red" "1 0" "$rc $?"
mkdir -p "$work/art/debian13/LM/deb"; printf 'x\n' >"$work/art/debian13/LM/deb/lm_5.0.0-1_amd64.deb"
gate debian13; expect "the same upstream, built first, is green" 0 $?
consumer "" "" "" no; gate debian13
expect "manifest tool without jsonschema in one recipe is red" 1 $?

consumer; gate nosuchslug; expect "an unknown slug cannot be judged" 2 $?
consumer; env PKG_DOCKER=no-such-docker "$tool" --slug debian13 --art "$work/art" --root "$work/repo" >"$work/log" 2>&1
expect "no docker cannot be judged" 2 $?

[ "$fail" -eq 0 ] || { echo "pkg-gate.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
