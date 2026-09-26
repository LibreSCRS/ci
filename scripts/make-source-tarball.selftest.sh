#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (GNU tar; macOS bsdtar lacks --sort)
# make-source-tarball.selftest.sh -- a consumer with a submodule, a vendored
# FetchContent dependency, the excluded directories and a tracked file its own
# .gitignore matches; asserts the members, the determinism across umask and
# time, and that every broken input is refused.
# shellcheck disable=SC2015  # pass and flunk always return 0, so A && pass || flunk is if-then-else
set -uo pipefail
# sedi <expr> <file>: edit in place on GNU and BSD sed alike (BSD `sed -i` takes
# the expression as a backup suffix and leaves the file as it was), and refuse
# a perturbation that changed nothing.
sedi() {
  sed -e "$1" "$2" >"$2.sedi" || { echo "FATAL: sed failed on $2" >&2; exit 2; }
  if cmp -s "$2" "$2.sedi"; then echo "FATAL: perturbation '$1' changed nothing in $2" >&2; exit 2; fi
  mv -f "$2.sedi" "$2"
}
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$here/make-source-tarball"
W="$(mktemp -d "/var/tmp/make-source-tarball-st.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
# Local submodules and vendor sources are file:// clones.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=s GIT_AUTHOR_EMAIL=s@e GIT_COMMITTER_NAME=s GIT_COMMITTER_EMAIL=s@e
cases=0 red=0 fails=0
pass() { cases=$((cases + 1)); printf 'ok    %s\n' "$1"; }
flunk() { cases=$((cases + 1)); printf 'FAIL  %s\n' "$1"; sed 's/^/  | /' "$W/log" 2>/dev/null | tail -n 8; fails=1; }
# red <name> <want-rc> <needle> -- the last run must have exited <want-rc> saying <needle>
red() {
  if [ "$rc" = "$2" ] && grep -qF -- "$3" "$W/log"; then red=$((red + 1)); pass "$1 (rc=$rc)"
  else flunk "$1: rc=$rc, want $2 with '$3'"; fi
}

mkrepo() { git init -q "$1" && git -C "$1" add -A && git -C "$1" commit -qm init; }
mkdir -p "$W/sub" "$W/dep"
echo sub >"$W/sub/file.c"; mkrepo "$W/sub"
echo dep >"$W/dep/CMakeLists.txt"; mkrepo "$W/dep"
echo moved >>"$W/dep/CMakeLists.txt"; git -C "$W/dep" commit -qam later
DEP1="$(git -C "$W/dep" rev-parse HEAD~1)"

R="$W/Pkg"
mkdir -p "$R/.github/workflows" "$R/build" "$R/debian" "$R/cmake" "$R/doc" "$R/extra"
echo 5.0.0 >"$R/VERSION"
echo 'on: push' >"$R/.github/workflows/ci.yml"
echo junk >"$R/build/x"; echo junk >"$R/debian/control"; echo x >"$R/extra/y"
echo '*.[0-9]' >"$R/doc/.gitignore"; echo 'man' >"$R/doc/tool.1"
printf 'FetchContent_Declare(dep\n  GIT_TAG %s\n)\n' "$DEP1" >"$R/cmake/FetchDep.cmake"
mkrepo "$R"
git -C "$R" add -f doc/tool.1 build/x debian/control
git -C "$R" submodule add -q "$W/sub" thirdparty/sub
git -C "$R" commit -qm sub
echo dirty >>"$R/VERSION.local"

VENDOR=(--vendor "thirdparty/dep=$W/dep@cmake/FetchDep.cmake")
run() { (cd "$W" && bash "$TOOL" "$@") >"$W/log" 2>&1; rc=$?; }
members() { tar -tzf "$1" | sort; }

# --- green: members --------------------------------------------------------
mkdir -p "$W/o1"
run --root "$R" --name pkg --out "$W/o1" "${VENDOR[@]}"
T="$W/o1/pkg_5.0.0.orig.tar.gz"
if [ "$rc" = 0 ] && [ -f "$T" ]; then pass "writes <name>_<version>.orig.tar.gz"; else flunk "writes <name>_<version>.orig.tar.gz (rc=$rc)"; fi
members "$T" >"$W/m1" 2>/dev/null
grep -qx 'Pkg-5.0.0/' "$W/m1" && ! grep -qv '^Pkg-5.0.0/' "$W/m1" && pass "one top directory, <Repo>-<version>" || flunk "one top directory, <Repo>-<version>"
grep -qx 'Pkg-5.0.0/thirdparty/sub/file.c' "$W/m1" && pass "the submodule's tree is carried" || flunk "the submodule's tree is carried"
grep -qx 'Pkg-5.0.0/doc/tool.1' "$W/m1" && pass "a tracked file its own .gitignore matches is kept" || flunk "a tracked file its own .gitignore matches is kept"
grep -qE '^Pkg-5.0.0/(\.github|build|debian)/' "$W/m1" && flunk ".github, build, debian are left out" || pass ".github, build, debian are left out"
grep -qE '(^|/)\.git(/|$)' "$W/m1" && flunk "no .git member" || pass "no .git member"
grep -q 'VERSION.local' "$W/m1" && flunk "the working tree's uncommitted file is not carried" || pass "the working tree's uncommitted file is not carried"
[ "$(tar -xzOf "$T" Pkg-5.0.0/thirdparty/dep/CMakeLists.txt)" = dep ] && pass "the vendored dependency is at its pin, not its head" || flunk "the vendored dependency is at its pin, not its head"

# --- determinism -----------------------------------------------------------
mkdir -p "$W/o2"
sleep 1
(umask 002; cd "$W" && bash "$TOOL" --root "$R" --name pkg --out "$W/o2" "${VENDOR[@]}") >"$W/log" 2>&1
cmp -s "$T" "$W/o2/pkg_5.0.0.orig.tar.gz" && pass "same commit, another second and umask: the same bytes" || flunk "same commit, another second and umask: the same bytes"
tar -tvzf "$T" | awk '{print $1, $2}' | sort -u >"$W/modes"
grep -qvE '^(-rw-r--r--|drwxr-xr-x|-rwxr-xr-x|lrwxr-xr-x) 0/0$' "$W/modes" && flunk "modes normalised, owner 0/0" || pass "modes normalised, owner 0/0"

# --- options ---------------------------------------------------------------
mkdir -p "$W/o3"
run --root "$R" --name pkg --out "$W/o3" --submodules no --exclude extra --version 9.9.9
members "$W/o3/pkg_9.9.9.orig.tar.gz" >"$W/m3" 2>/dev/null
if [ "$rc" = 0 ] && ! grep -q 'thirdparty/sub/file.c' "$W/m3" && ! grep -q '/extra/' "$W/m3" && grep -qx 'Pkg-9.9.9/' "$W/m3"; then
  pass "--submodules no, --exclude and --version act"
else flunk "--submodules no, --exclude and --version act"; fi
mkdir -p "$W/o4"
GITHUB_REPOSITORY=LibreSCRS/Named REPO_ROOT="$R" run --name pkg --out "$W/o4"
members "$W/o4/pkg_5.0.0.orig.tar.gz" >"$W/m4" 2>/dev/null
grep -qx 'Named-5.0.0/' "$W/m4" && ! grep -qv '^Named-5.0.0/' "$W/m4" && pass "root and top name from the environment" || flunk "root and top name from the environment"

# --- refused ---------------------------------------------------------------
cp -r "$R" "$W/nopin"; : >"$W/nopin/cmake/FetchDep.cmake"; git -C "$W/nopin" commit -qam nopin
run --root "$W/nopin" --name pkg --out "$W/o5" --vendor "thirdparty/dep=$W/dep@cmake/FetchDep.cmake"
red "a vendor pin file without a pin is refused" 1 "found 0"
cp -r "$R" "$W/twopin"; printf '  GIT_TAG %s\n' "$DEP1" >>"$W/twopin/cmake/FetchDep.cmake"; git -C "$W/twopin" commit -qam twopin
run --root "$W/twopin" --name pkg --out "$W/o5" --vendor "thirdparty/dep=$W/dep@cmake/FetchDep.cmake"
red "a vendor pin file with two pins is refused" 1 "found 2"
cp -r "$R" "$W/nocommit"; sedi "s/$DEP1/3333333333333333333333333333333333333333/" "$W/nocommit/cmake/FetchDep.cmake"; git -C "$W/nocommit" commit -qam nocommit
run --root "$W/nocommit" --name pkg --out "$W/o5" --vendor "thirdparty/dep=$W/dep@cmake/FetchDep.cmake"
red "a pin the vendor source does not have is refused" 1 "has no commit"
cp -r "$R" "$W/nover"; git -C "$W/nover" rm -q VERSION; git -C "$W/nover" commit -qm nover; rm -f "$W/nover/VERSION"
run --root "$W/nover" --name pkg --out "$W/o5"
red "no VERSION cannot be judged" 2 "no VERSION"
run --root "$R" --out "$W/o5"
red "no --name is a usage error" 2 "usage:"
run --root "$R" --name pkg --submodules maybe
red "--submodules takes yes or no" 2 "usage:"
run --root "$W/does-not-exist" --name pkg
red "no repository cannot be judged" 2 "no repository"

[ "$fails" = 0 ] || { echo "make-source-tarball selftest: FAILED"; exit 1; }
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
