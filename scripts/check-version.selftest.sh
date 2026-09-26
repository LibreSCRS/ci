#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1007,SC2015,SC2016,SC2028,SC2086,SC2181  # fixture text is literal; $L/$F/$S split on purpose; A && B || C report lines
# Self-test for check-version.sh: one green anchor per arm, and one case per
# distinct branch that can go red (1) or refuse to judge (2) -- not one per
# shape of data that reaches the same branch. Every red case below was proved
# by perturbing that branch of the gate and watching this file go red.
#
# Every case runs from / with REPO_ROOT naming the fixture, because the gate
# does not sit in the tree it judges.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
subject="$here/check-version.sh"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }

work=$(mktemp -d "/var/tmp/check-version-selftest.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
out="$work/out"
fails=0 cases=0 red=0

run() {   # run <name> <expected-rc> <dir> [args...]
    local name=$1 want=$2 dir=$3 got
    shift 3
    cases=$((cases + 1))
    # red-proved: the case in which the gate returned non-zero on a perturbed input.
    [ "$want" = 0 ] || red=$((red + 1))
    ( cd / && REPO_ROOT="$dir" bash "$subject" "$@" ) > "$out" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-60s rc=%s\n' "$name" "$got"
    else
        printf '  FAIL  %-60s rc=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$out"
        fails=$((fails + 1))
    fi
}
says() {  # says <name> <yes|no> <pattern> -- about the last run's output
    local got=no
    grep -q -- "$3" "$out" && got=yes
    if [ "$got" = "$2" ]; then
        printf '  ok    %-60s said=%s\n' "$1" "$got"
    else
        printf '  FAIL  %-60s said=%s want=%s (%s)\n' "$1" "$got" "$2" "$3"
        sed 's/^/          /' "$out"
        fails=$((fails + 1))
    fi
}
mkrepo() {  # mkrepo <dir> <version>
    mkdir -p "$1"
    ( cd "$1" && git init -q . && printf '%s\n' "$2" > VERSION && git add VERSION ) >/dev/null 2>&1
}
add() {     # add <dir> <relpath> <content> -- `git add` is enough; git grep reads the index
    mkdir -p "$(dirname -- "$1/$2")"
    printf '%s\n' "$3" > "$1/$2"
    ( cd "$1" && git add -- "$2" ) >/dev/null 2>&1
}
changelog() { printf '# Changelog\n\n%b' "$2" > "$1/CHANGELOG.md"; }

echo "-- lockstep arm"
L="--arms lockstep --version 5.0.0"
d=$work/l_ok; mkdir -p "$d"; changelog "$d" '## [Unreleased] — 5.0.0\n\n- entry\n'; echo 5.0.0 > "$d/VERSION"
run "lockstep: changelog and VERSION agree" 0 "$d" $L
# The one that shipped: a heading with nothing under it.
d=$work/l1; mkdir -p "$d"; changelog "$d" '## [Unreleased] — 5.0.0\n\n## [4.2.0]\n\n- old\n'; echo 5.0.0 > "$d/VERSION"
run "lockstep: an empty section under the heading" 1 "$d" $L
d=$work/l2; mkdir -p "$d"; changelog "$d" '## 5.0.0\n\n- entry\n'; echo 5.0.0 > "$d/VERSION"
run "lockstep: a bracket-less heading is found" 0 "$d" $L
# Without escaping the dots 5.0.0 also matches [500.0].
d=$work/l3; mkdir -p "$d"; changelog "$d" '## [500.0]\n\n- wrong\n'; echo 5.0.0 > "$d/VERSION"
run "lockstep: 5.0.0 does not match [500.0]" 1 "$d" $L
d=$work/l4; mkdir -p "$d"; changelog "$d" '## [Unreleased] — 5.0.0\n\n- entry\n'; echo 4.2.0 > "$d/VERSION"
run "lockstep: VERSION disagrees with the version asked for" 1 "$d" $L
says "lockstep: ... and the message names VERSION" yes "VERSION file holds '4.2.0'"
d=$work/l5; mkdir -p "$d"; changelog "$d" '## [5.0.0]\n\n- entry\n'; : > "$d/VERSION"
run "lockstep: no version at all cannot be judged" 2 "$d" --arms lockstep
# --section: a pre-release falls back to its base version's section, only when
# it has none of its own, and a miss is exit 1.
d=$work/l6; mkdir -p "$d"; changelog "$d" '## [5.0.0] — 2026-10-01\n\n- final entry\n'; echo 5.0.0 > "$d/VERSION"
run "--section 5.0.0-rc1 falls back to [5.0.0]" 0 "$d" --section 5.0.0-rc1
says "--section ... and prints that section" yes "final entry"
d=$work/l7; mkdir -p "$d"; changelog "$d" '## [5.0.0-rc1]\n\n- rc entry\n\n## [5.0.0]\n\n- final entry\n'; echo 5.0.0 > "$d/VERSION"
run "--section 5.0.0-rc1 over its own section" 0 "$d" --section 5.0.0-rc1
says "--section ... prints the rc section, not the final" no "final entry"
d=$work/l8; mkdir -p "$d"; changelog "$d" '## [4.2.0]\n\n- older\n'; echo 5.0.0 > "$d/VERSION"
run "--section with neither section" 1 "$d" --section 5.0.0-rc1

echo "-- floors arm"
F="--arms floors"
PROJ='project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
floor() {  # floor <name> <want> <version> <path=line>... [-- args...]
    local name=$1 want=$2 d="$work/f$cases"
    mkrepo "$d" "$3"
    shift 3
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do add "$d" "${1%%=*}" "${1#*=}"; shift; done
    [ "$#" -gt 0 ] && shift
        run "floors: $name" "$want" "$d" $F "$@"
}
floor "an agreeing floor" 0 5.0.0 'CMakeLists.txt=find_package(LibreMiddleware 5.0 REQUIRED CONFIG)'
# Equality, not >=: SameMajorVersion refuses a floor above as well as below.
floor "a floor a major above VERSION" 1 5.0.0 'CMakeLists.txt=find_package(LibreAgent 6.0 REQUIRED CONFIG)'
floor "a range floors at its low end" 1 5.0.0 'docs/CONSUMERS.md=find_package(LibreMiddleware 4.1...<5.0 REQUIRED CONFIG)'
floor "CHANGELOG is exempt" 0 5.0.0 'CHANGELOG.md=- a `find_package(LibreAgent 4.2 ...)` floor no longer applies'
floor "thirdparty is exempt" 0 5.0.0 'thirdparty/foo/CMakeLists.txt=find_package(LibreMiddleware 4.0 REQUIRED CONFIG)'
floor "find_dependency counts" 1 5.0.0 'cmake/Config.cmake.in=find_dependency(LibreMiddleware 4.2 REQUIRED CONFIG)'
floor "a second call on the same line is seen" 1 5.0.0 \
    'CMakeLists.txt=find_package(LibreAgent 5.0 CONFIG) find_package(LibreMiddleware 4.0 CONFIG)'
# The vacuum: --min says how many floors the caller knows exist.
floor "no floors under --min 1" 1 5.0.0 "CMakeLists.txt=$PROJ" -- --min 1
d=$work/f_nogit; mkdir -p "$d"; echo 5.0.0 > "$d/VERSION"
run "floors: outside a git checkout cannot be judged" 2 "$d" $F
floor "no VERSION cannot be judged" 2 '' 'CMakeLists.txt=find_package(LibreMiddleware 4.0 REQUIRED CONFIG)'
# Per-package expectations, for the window a major bump opens.
LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=6"; export LIBRESCRS_FLOOR_MAJOR
floor "an expectation keyed per package" 0 5.0.0 'CMakeLists.txt=find_package(LibreMiddleware 6.0 REQUIRED CONFIG)' \
    'cmake/Config.cmake.in=find_dependency(LibreAgent 5.0 REQUIRED CONFIG)'
LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=six"
floor "an unparsable override cannot be judged" 2 5.0.0 'CMakeLists.txt=find_package(LibreMiddleware 5.0 REQUIRED CONFIG)'
unset LIBRESCRS_FLOOR_MAJOR
# The whole floor, for the package this repository ships (project() names it).
floor "a minor pin above what this repository ships" 1 5.0.0 "CMakeLists.txt=$PROJ" \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
floor "a minor pin the shipped package satisfies" 0 5.0.0 "CMakeLists.txt=$PROJ" \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.0...<6.0 REQUIRED CONFIG)'
floor "a minor pin on another component is not judged" 0 5.0.0 "CMakeLists.txt=$PROJ" \
    'src/CMakeLists.txt=find_package(LibreAgent 5.4 REQUIRED CONFIG)'
# An override naming ANOTHER major stands the whole comparison down, and says
# so; one repeating VERSION's own major changes nothing.
LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=6"; export LIBRESCRS_FLOOR_MAJOR
floor "a per-package override on another major stands it down" 0 5.0.0 "CMakeLists.txt=$PROJ" \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 6.1...<7.0 REQUIRED CONFIG)'
LIBRESCRS_FLOOR_MAJOR="6"
floor "a bare override on another major stands it down" 0 5.0.0 "CMakeLists.txt=$PROJ" \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 6.1...<7.0 REQUIRED CONFIG)'
says "floors: ... and the stand-down names itself" yes "compared by major only"
LIBRESCRS_FLOOR_MAJOR="5"
floor "repeating VERSION's own major is not a change" 1 5.0.0 "CMakeLists.txt=$PROJ" \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
unset LIBRESCRS_FLOOR_MAJOR
# The top of a range: by value (exclusive and inclusive) and by major.
floor "an exclusive top at what this tree ships" 1 5.1.0 'CMakeLists.txt=project(LibreMiddleware VERSION 5.1.0 LANGUAGES CXX)' \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.0...<5.1 REQUIRED CONFIG)'
floor "an inclusive top below what this tree ships" 1 5.1.0 'CMakeLists.txt=project(LibreMiddleware VERSION 5.1.0 LANGUAGES CXX)' \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.0...5.0 REQUIRED CONFIG)'
floor "an inclusive top in the next major" 1 5.0.0 "CMakeLists.txt=$PROJ" \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.0...6.0 REQUIRED CONFIG)'
says "floors: ... and the message names the line it left" yes "outside the major 5 line"
floor "an exclusive top past the next major" 1 5.0.0 "CMakeLists.txt=$PROJ" \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.0...<7.0 REQUIRED CONFIG)'
# --list is inspection: exit 0, and it carries the verdict the check reaches.
floor "--list exits 0 over a floor the check rejects" 0 5.0.0 "CMakeLists.txt=$PROJ" \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)' -- --list
says "floors: --list names the verdict" yes "UNSATISFIABLE"
# No project(): the whole-floor comparison cannot be set up. Under --min that
# is rc=2; without it the note stands and says why the run is green.
floor "no project() under --min cannot be judged" 2 5.0.0 \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)' -- --min 1
floor "no project() without --min keeps a note" 0 5.0.0 \
    'docs/CONSUMERS.md=find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
says "floors: ... and the note is the reason it is green" yes "compared by major only"

echo "-- stamp arm"
# A version module of the shape each case names: newer-wins | tag-wins | no-git
module() {
    mkdir -p "$1/cmake"
    {
        echo 'if(NOT DEFINED GIT_EXECUTABLE)'
        echo '    find_package(Git QUIET REQUIRED)'
        echo 'endif()'
        echo 'set(SRC_DIR "${CMAKE_CURRENT_LIST_DIR}/..")'
        echo 'set(V "")'
        if [ "$2" != "no-git" ]; then
            echo 'if(GIT_EXECUTABLE)'
            echo '  execute_process(COMMAND ${GIT_EXECUTABLE} describe --tags'
            echo '    WORKING_DIRECTORY ${SRC_DIR} OUTPUT_VARIABLE V RESULT_VARIABLE E'
            echo '    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)'
            echo '  if(E)'
            echo '    set(V "")'
            echo '  endif()'
            echo 'endif()'
        fi
        echo 'set(F "")'
        echo 'if(EXISTS "${SRC_DIR}/VERSION")'
        echo '  file(STRINGS "${SRC_DIR}/VERSION" F LIMIT_COUNT 1)'
        echo '  string(STRIP "${F}" F)'
        echo 'endif()'
        echo 'if(V STREQUAL "")'
        echo '  set(V "${F}")'
        if [ "$2" = "newer-wins" ]; then
            echo 'elseif(NOT F STREQUAL "")'
            echo '  string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+" VT "${V}")'
            echo '  string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+" FT "${F}")'
            echo '  if(FT VERSION_GREATER VT)'
            echo '    set(V "${FT}")'
            echo '  endif()'
        fi
        echo 'endif()'
        echo 'if(NOT V)'
        echo '  set(V 0.0.1)'
        echo 'endif()'
        echo 'string(REGEX MATCH "^([0-9]+)\\.([0-9]+)\\.([0-9]+)" M "${V}")'
        echo 'set(GIT_VERSION_MAJOR ${CMAKE_MATCH_1})'
        echo 'set(GIT_VERSION_MINOR ${CMAKE_MATCH_2})'
        echo 'set(GIT_VERSION_PATCH ${CMAKE_MATCH_3})'
    } > "$1/cmake/GitVersion.cmake"
}

project_file() {
    {
        echo 'cmake_minimum_required(VERSION 3.24)'
        echo 'include(cmake/GitVersion.cmake)'
        echo 'project(StampFixture VERSION ${GIT_VERSION_MAJOR}.${GIT_VERSION_MINOR}.${GIT_VERSION_PATCH} LANGUAGES NONE)'
    } > "$1/CMakeLists.txt"
}

stamp() {  # stamp <name> <want> <flavour|-> [<VERSION>]
    local d="$work/s$cases"
    mkdir -p "$d"
    [ "$3" = - ] || { module "$d" "$3"; project_file "$d"; }
    [ -z "${4:-}" ] || echo "$4" > "$d/VERSION"
    run "stamp: $1" "$2" "$d" --arms stamp
}
stamp "the file wins when the tag is behind, the tag when ahead" 0 newer-wins 5.0.0
stamp "describe decides: a stale tag stamps the old major" 1 tag-wins 5.0.0
stamp "git ignored: a tag ahead of VERSION is not stamped" 1 no-git 5.0.0
stamp "no VERSION cannot be judged" 2 newer-wins
stamp "no CMakeLists.txt cannot be judged" 2 - 5.0.0
d=$work/s_dies; mkdir -p "$d"; module "$d" newer-wins; echo 5.0.0 > "$d/VERSION"
printf 'cmake_minimum_required(VERSION 3.24)\nmessage(FATAL_ERROR "dies before project()")\n' > "$d/CMakeLists.txt"
run "stamp: a configure that never reaches project() cannot be judged" 2 "$d" --arms stamp

echo "-- surfaces arm"
S="--arms surfaces"
fixture() {   # fixture <dir> <cmake-version> <metadata-version> <plist-version> <yaml-version>
    d=$1
    mkdir -p "$d/ci" "$d/pkg" "$d/app"
    printf '5.0.0\n' > "$d/VERSION"
    cat > "$d/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.24.0 FATAL_ERROR)
project(Fixture VERSION $2 LANGUAGES NONE)
EOF
    # X-Plasma-API-Minimum-Version is here on purpose: its key ENDS in
    # "Version", so a loose pattern reads 6.0 as the applet's version.
    cat > "$d/pkg/metadata.json" <<EOF
{
    "KPlugin": {
        "Id": "org.librescrs.smartcard",
        "Version": "$3"
    },
    "X-Plasma-API-Minimum-Version": "6.0"
}
EOF
    cat > "$d/app/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>$4</string>
</dict>
</plist>
EOF
    cat > "$d/project.yml" <<EOF
targets:
  App:
    info:
      properties:
        CFBundleShortVersionString: $5
        CFBundleVersion: 1
EOF
    printf '# <kind> <path>\ncmake-project        .\nplasma-metadata      pkg/metadata.json\nplist-short-version  app/Info.plist\nyaml-short-version   project.yml\n' \
        > "$d/ci/version-surfaces.txt"
}

list() { printf '%b' "$2" > "$1/ci/version-surfaces.txt"; }
d=$work/u_ok; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
run "surfaces: every surface agrees" 0 "$d" $S
says "surfaces: ... all four counted, CFBundleVersion not read" yes 'all 4 version surface(s) state 5.0.0'
for c in "project() 0.1.0 5.0.0 5.0.0 5.0.0 project(Fixture) in . states '0.1.0'" \
         "metadata 5.0.0 0.1.0 5.0.0 5.0.0 pkg/metadata.json (KPlugin.Version) states '0.1.0'" \
         "plist 5.0.0 5.0.0 0.1 5.0.0 app/Info.plist (CFBundleShortVersionString) states '0.1'" \
         "xcodegen 5.0.0 5.0.0 5.0.0 0.1.0 project.yml (CFBundleShortVersionString) states '0.1.0'"; do
    read -r what a b p y msg <<< "$c"
    d=$work/u_$what; fixture "$d" "$a" "$b" "$p" "$y"
        run "surfaces: $what states something else" 1 "$d" $S
    says "surfaces: ... and the message names it" yes "$msg"
done
d=$work/u6; fixture "$d" 5.0.0 '@PROJECT_VERSION@' 5.0.0 5.0.0
run "surfaces: an unexpanded placeholder in the installed file" 1 "$d" $S
says "surfaces: ... and the message names the placeholder" yes 'still holds the literal @PROJECT_VERSION@'
d=$work/u7; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
sed 's/"Version": "5.0.0"/"Version": "@PROJECT_VERSION@"/' "$d/pkg/metadata.json" > "$d/pkg/metadata.json.in"
rm "$d/pkg/metadata.json"
run "surfaces: a metadata template is accepted" 0 "$d" $S
says "surfaces: ... and the summary counts it as templated" yes '1 read the number'
d=$work/u8; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; printf 'v5.0.0\n' > "$d/VERSION"
run "surfaces: a v-prefixed VERSION is the same version" 0 "$d" $S
# Each way the arm could be wrong about the tree rather than the tree wrong.
d=$work/u9; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; rm "$d/VERSION"
run "surfaces: no VERSION cannot be judged" 2 "$d" $S
d=$work/u10; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; list "$d" '# nothing listed\n'
run "surfaces: an empty list cannot be judged" 2 "$d" $S
d=$work/u11; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; rm "$d/ci/version-surfaces.txt"
run "surfaces: a missing list cannot be judged" 2 "$d" $S
d=$work/u12; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; list "$d" 'plist-shortversion  app/Info.plist\n'
run "surfaces: an unknown kind cannot be judged" 2 "$d" $S
d=$work/u13; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; list "$d" 'plist-short-version  app/Gone.plist\n'
run "surfaces: a listed file that is missing cannot be judged" 2 "$d" $S
d=$work/u14; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
cases=$((cases + 1)); red=$((red + 1))
( cd / && REPO_ROOT="$d" CMAKE=/nonexistent/cmake bash "$subject" $S ) > "$out" 2>&1
[ "$?" = 2 ] && printf '  ok    %-60s rc=2\n' "surfaces: no cmake cannot be judged" \
    || { printf '  FAIL  %-60s\n' "surfaces: no cmake cannot be judged"; sed 's/^/          /' "$out"; fails=$((fails + 1)); }
d=$work/u15; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
printf 'cmake_minimum_required(VERSION 3.24.0 FATAL_ERROR)\nmessage(FATAL_ERROR "died early")\n' > "$d/CMakeLists.txt"
run "surfaces: a configure that dies before project() cannot be judged" 2 "$d" $S
# CMake supplies an implicit project(Project) with no version: not a mismatch.
d=$work/u16; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
printf 'cmake_minimum_required(VERSION 3.24.0 FATAL_ERROR)\nproject(Fixture LANGUAGES NONE)\n' > "$d/CMakeLists.txt"
run "surfaces: project() with no VERSION cannot be judged" 2 "$d" $S
# A .plist.in states no number of its own: accepted as a template only beside
# a cmake-project row (wherever that row stands in the list), refused as a
# literal, and the placeholder in a plain plist is still a mismatch.
plist_in() {  # plist_in <dir> <plist-version> <list>
    fixture "$1" 5.0.0 5.0.0 "$2" 5.0.0
    mv "$1/app/Info.plist" "$1/app/Info.plist.in"
    list "$1" "$3"
}
d=$work/u17; plist_in "$d" '@PROJECT_VERSION@' 'plist-short-version  app/Info.plist.in\ncmake-project        .\n'
run "surfaces: a plist template beside a measured surface" 0 "$d" $S
d=$work/u18; plist_in "$d" 4.9.9 'cmake-project        .\nplist-short-version  app/Info.plist.in\n'
run "surfaces: a literal inside a plist template is refused" 1 "$d" $S
d=$work/u19; plist_in "$d" '@PROJECT_VERSION@' 'plist-short-version  app/Info.plist.in\n'
run "surfaces: a plist template with nothing measured cannot be judged" 2 "$d" $S
d=$work/u20; fixture "$d" 5.0.0 5.0.0 '@PROJECT_VERSION@' 5.0.0
list "$d" 'cmake-project        .\nplist-short-version  app/Info.plist\n'
run "surfaces: the placeholder in a plain plist is a mismatch" 1 "$d" $S
# Packaging metadata: a Debian changelog, an RPM spec, a version helper.
pkgfixture() {   # pkgfixture <dir> <deb-version> <rpm-version> <helper-prints>
    d=$1
    mkdir -p "$d/ci" "$d/packaging/debian" "$d/packaging/rpm" "$d/scripts"
    printf '5.0.0\n' > "$d/VERSION"
    printf 'fixture (%s) unstable; urgency=medium\n\n  * entry\n\n -- A <a@b.c>  Mon, 01 Jan 2026 00:00:00 +0000\n' \
        "$2" > "$d/packaging/debian/changelog"
    printf 'Name:           fixture\nVersion:        %s\nRelease:        1%%{?dist}\n' "$3" \
        > "$d/packaging/rpm/fixture.spec"
    printf 'project_version() { printf %%s "%s"; }\n' "$4" > "$d/scripts/project-version.sh"
    printf '# <kind> <path>\ndebian-changelog     packaging/debian/changelog\nrpm-spec-version     packaging/rpm/fixture.spec\nshell-version-helper scripts/project-version.sh\n' \
        > "$d/ci/version-surfaces.txt"
}

d=$work/u21; pkgfixture "$d" 4.2.0-1 5.0.0 5.0.0
run "surfaces: the Debian changelog states another version" 1 "$d" $S
says "surfaces: ... and names the generator" yes "regenerate packaging/debian/changelog with"
d=$work/u22; pkgfixture "$d" 5.0.0-1 5.0.0 5.0.0
run "surfaces: 5.0.0-1 agrees with 5.0.0 (the revision is packaging's)" 0 "$d" $S
d=$work/u23; pkgfixture "$d" 5.0.0-1 4.2.0 5.0.0
run "surfaces: the RPM spec states another version" 1 "$d" $S
d=$work/u24; pkgfixture "$d" 5.0.0-1 5.0.0 4.2.0
run "surfaces: the version helper prints another version" 1 "$d" $S
# The helper is asked with an ABSOLUTE root, as its callers ask it: a relative
# "." misses its git guard and the VERSION file answers for the wrong reason.
d=$work/u25; pkgfixture "$d" 5.0.0-1 5.0.0 5.0.0
cat > "$d/scripts/project-version.sh" <<'SH'
project_version() {
    root="$1"; version=""
    toplevel="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$toplevel" ] && [ "$toplevel" = "$root" ]; then
        version="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)"
    fi
    if [ -z "$version" ] && [ -r "$root/VERSION" ]; then
        version="$(head -n1 "$root/VERSION" | tr -d '[:space:]')"
    fi
    printf '%s' "${version:-dev}"
}
SH
printf '# <kind> <path>\nshell-version-helper scripts/project-version.sh\n' > "$d/ci/version-surfaces.txt"
( cd "$d" && git init -q . && git add -A \
    && git -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q -m t \
    && git -c tag.gpgSign=false tag 4.2.0 ) || { echo "  FAIL  case_28 could not build the git fixture"; fails=$((fails + 1)); }
relative=$( cd "$d" && sh -c '. scripts/project-version.sh; project_version .' )
[ "$relative" = 5.0.0 ] \
    || { printf '  FAIL  %-58s (relative call printed %s)\n' "case_28 fixture: the relative call hides the tag" "$relative"; fails=$((fails + 1)); }
run "surfaces: the helper is judged through an absolute root" 1 "$d" $S
says "surfaces: ... and the older tag is what it reports" yes "states '4.2.0'"

echo "-- the merged gate"
whole() {  # whole <dir>: a tree on which every arm agrees
    d=$1; mkrepo "$d" 5.0.0; module "$d" newer-wins; project_file "$d"
    changelog "$d" '## [Unreleased] — 5.0.0\n\n- entry\n'
    mkdir -p "$d/ci"; printf 'rpm-spec-version  pkg.spec\n' > "$d/ci/version-surfaces.txt"
    printf 'Name: x\nVersion: 5.0.0\n' > "$d/pkg.spec"
    add "$d" src/CMakeLists.txt 'find_package(LibreAgent 5.0 REQUIRED CONFIG)'
}
d=$work/m1; whole "$d"
run "every arm agrees on a whole tree" 0 "$d"
says "... and all four arms ran" yes "4 arm(s) run, verdict rc=0"
d=$work/m2; whole "$d"; add "$d" src/b.cmake 'find_package(LibreAgent 4.0 REQUIRED CONFIG)'
run "one arm red makes the gate red" 1 "$d"
says "... and the red arm is named" yes "floors rc=1"
d=$work/m3; whole "$d"; rm "$d/ci/version-surfaces.txt"
run "one arm unmeasurable, the rest green, is rc=2" 2 "$d"
d=$work/m4; whole "$d"; rm "$d/ci/version-surfaces.txt"; add "$d" src/b.cmake 'find_package(LibreAgent 4.0 REQUIRED CONFIG)'
run "a red arm outranks an unmeasurable one" 1 "$d"
d=$work/m1
run "an unknown arm cannot be judged" 2 "$d" --arms lockstep,flors
run "an arm named twice cannot be judged" 2 "$d" --arms lockstep,lockstep
run "an empty arm list cannot be judged" 2 "$d" --arms ''
run "--version overrides VERSION for the lockstep" 1 "$d" --arms lockstep --version 5.0.1
run "an unknown option is a usage error" 2 "$d" --frobnicate
cases=$((cases + 1)); red=$((red + 1))
( cd / && env -u REPO_ROOT -u GITHUB_WORKSPACE bash "$subject" ) > "$out" 2>&1
[ "$?" = 2 ] && printf '  ok    %-60s rc=2\n' "no consumer tree at all" \
    || { printf '  FAIL  %-60s\n' "no consumer tree at all"; fails=$((fails + 1)); }
cases=$((cases + 1))
( cd / && GITHUB_WORKSPACE="$work/m2" REPO_ROOT="$work/m1" bash "$subject" ) > "$out" 2>&1
[ "$?" = 0 ] && printf '  ok    %-60s rc=0\n' "REPO_ROOT wins over a (red) workspace" \
    || { printf '  FAIL  %-60s\n' "REPO_ROOT wins over a (red) workspace"; fails=$((fails + 1)); }

if [ "$fails" -eq 0 ]; then
    echo "check-version selftest: all $cases cases passed"
else
    echo "check-version selftest: $fails of $cases case(s) failed"
fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fails" -eq 0 ]
