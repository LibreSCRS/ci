#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC1007,SC2010,SC2012,SC2015,SC2016,SC2028,SC2181  # fixture text is literal on purpose; A && B || C report lines
# Self-test for check-version.sh: the four arms' own cases, each run through
# the merged gate with --arms, then the cases the merge itself adds (how the
# arms' verdicts combine, and which tree is judged).
#
# Every case runs from / with REPO_ROOT naming the fixture, because the gate
# no longer sits in the tree it judges.
#
# Lockstep: each case a mistake the original inline release step's comments
# name as real. Floors: every case a shape that actually occurred, or a way the
# gate could pass on a tree it did not measure. Stamp: three-line CMake
# projects with LANGUAGES NONE, each carrying a version module of a shape that
# has really been written. Surfaces: each case a way the check could be wrong
# about the tree rather than the tree being wrong; the rc=2 cases matter most.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
subject="$here/check-version.sh"
GATE="$subject"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/var/tmp}/check-version-selftest.XXXXXX") || exit 2
WORK="$work"
trap 'rm -rf "$work"' EXIT
fails=0
cases=0
red=0

echo "-- lockstep arm"
run() {   # run <name> <expected-rc> <dir>  [args...]
    name=$1; want=$2; dir=$3; shift 3
    cases=$((cases + 1))
    # red-proved: the case in which the gate returned non-zero on a perturbed input.
    if [ "$want" != 0 ]; then red=$((red + 1)); fi
    ( cd / && REPO_ROOT="$dir" bash "$subject" "$@" ) > "$work/out" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-52s rc=%s\n' "$name" "$got"
    else
        printf '  FAIL  %-52s rc=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$work/out"
        fails=$((fails + 1))
    fi
}

# case_1 -- a heading with nothing under it must FAIL. This is the one that
# actually shipped: testing for the header alone let it pass and the release
# went out with generic auto-notes.
d=$work/case_1; mkdir -p "$d"
printf '# Changelog\n\n## [Unreleased] — 5.0.0\n\n## [4.2.0]\n\n- something\n' > "$d/CHANGELOG.md"
printf '5.0.0\n' > "$d/VERSION"
run "case_1 empty section under the heading" 1 "$d" --arms lockstep --version 5.0.0

# case_2 -- a bracket-less heading must PASS. The extractor reads it correctly;
# a near-miss pattern once reported it as missing, and that was the bug.
d=$work/case_2; mkdir -p "$d"
printf '# Changelog\n\n## 5.0.0\n\n- a real entry\n' > "$d/CHANGELOG.md"
printf '5.0.0\n' > "$d/VERSION"
run "case_2 bracket-less heading is found" 0 "$d" --arms lockstep --version 5.0.0

# case_3 -- 5.0.0 must NOT match a [500.0] heading. Without escaping the dots
# the regex's `.` matches the `0` and the wrong section is accepted.
d=$work/case_3; mkdir -p "$d"
printf '# Changelog\n\n## [500.0]\n\n- the wrong section\n' > "$d/CHANGELOG.md"
printf '5.0.0\n' > "$d/VERSION"
run "case_3 unescaped dot must not match [500.0]" 1 "$d" --arms lockstep --version 5.0.0

# case_4 -- a VERSION that disagrees must fail, and say so about VERSION.
d=$work/case_4; mkdir -p "$d"
printf '# Changelog\n\n## [Unreleased] — 5.0.0\n\n- a real entry\n' > "$d/CHANGELOG.md"
printf '4.2.0\n' > "$d/VERSION"
run "case_4 VERSION disagrees with the version asked for" 1 "$d" --arms lockstep --version 5.0.0
( cd / && REPO_ROOT="$d" bash "$subject" --arms lockstep --version 5.0.0 2>&1 ) | grep -q "VERSION file holds '4.2.0'" \
    && printf '  ok    %-52s\n' "case_4 the message names VERSION, not the changelog" \
    || { printf '  FAIL  %-52s\n' "case_4 the message names VERSION, not the changelog"; fails=$((fails + 1)); }

# case_5 -- an absent CHANGELOG is the no-section case, reported, not a crash.
d=$work/case_5; mkdir -p "$d"
printf '5.0.0\n' > "$d/VERSION"
run "case_5 absent CHANGELOG is reported, not fatal" 1 "$d" --arms lockstep --version 5.0.0

# case_6 -- the happy path, so a check that fails everything cannot pass this.
d=$work/case_6; mkdir -p "$d"
printf '# Changelog\n\n## [Unreleased] — 5.0.0\n\n- a real entry\n' > "$d/CHANGELOG.md"
printf '5.0.0\n' > "$d/VERSION"
run "case_6 agreeing changelog and VERSION" 0 "$d" --arms lockstep --version 5.0.0

# case_7 -- no version to check is not a silent pass: no --version and an
# empty VERSION file leave the lockstep arm with nothing to compare, and a
# --version with no value is a usage error.
d=$work/case_7; mkdir -p "$d"
printf '# Changelog\n\n## [5.0.0]\n\n- entry\n' > "$d/CHANGELOG.md"
: > "$d/VERSION"
run "case_7 no version at all" 2 "$d" --arms lockstep
run "case_7b --version with no value" 2 "$d" --arms lockstep --version

# case_8 -- a pre-release tag extracts the section its final version names.
# Without the fallback the rehearsal fell back to generated notes, so the one
# run meant to exercise the tag path never did.
d=$work/case_8; mkdir -p "$d"
printf '# Changelog\n\n## [5.0.0] — 2026-10-01\n\n- final entry\n' > "$d/CHANGELOG.md"
printf '5.0.0\n' > "$d/VERSION"
run "case_8 --section 5.0.0-rc1 over a [5.0.0] section" 0 "$d" --section 5.0.0-rc1
( cd / && REPO_ROOT="$d" bash "$subject" --section 5.0.0-rc1 2>&1 ) | grep -q "final entry" \
    && printf '  ok    %-52s\n' "case_8 the body is the 5.0.0 section" \
    || { printf '  FAIL  %-52s\n' "case_8 the body is the 5.0.0 section"; fails=$((fails + 1)); }

# case_9 -- a repository that DOES keep a pre-release section gets that one;
# the fallback must not fire when the exact version has a section.
d=$work/case_9; mkdir -p "$d"
printf '# Changelog\n\n## [5.0.0-rc1] — 2026-09-30\n\n- rc entry\n\n## [5.0.0] — 2026-10-01\n\n- final entry\n' > "$d/CHANGELOG.md"
printf '5.0.0\n' > "$d/VERSION"
run "case_9 --section 5.0.0-rc1 over its own section" 0 "$d" --section 5.0.0-rc1
out9=$( cd / && REPO_ROOT="$d" bash "$subject" --section 5.0.0-rc1 2>&1 )
if printf '%s' "$out9" | grep -q "rc entry" && ! printf '%s' "$out9" | grep -q "final entry"; then
    printf '  ok    %-52s\n' "case_9 the body is the rc section, not the final"
else
    printf '  FAIL  %-52s\n' "case_9 the body is the rc section, not the final"; fails=$((fails + 1))
fi

# case_10 -- neither the pre-release nor its base version has a section.
d=$work/case_10; mkdir -p "$d"
printf '# Changelog\n\n## [4.2.0]\n\n- older\n' > "$d/CHANGELOG.md"
printf '5.0.0\n' > "$d/VERSION"
run "case_10 --section 5.0.0-rc1 with neither section" 1 "$d" --section 5.0.0-rc1

# case_11 -- the agreement check is NOT loosened: asserting 5.0.0 over a
# changelog that only names 5.0.0-rc1 still fails.
d=$work/case_11; mkdir -p "$d"
printf '# Changelog\n\n## [5.0.0-rc1] — 2026-09-30\n\n- rc entry\n' > "$d/CHANGELOG.md"
printf '5.0.0\n' > "$d/VERSION"
run "case_11 assert 5.0.0 over only a [5.0.0-rc1] section" 1 "$d" --arms lockstep --version 5.0.0


echo "-- floors arm"
mkrepo() {  # mkrepo <dir> <version>
    mkdir -p "$1"
    ( cd "$1" && git init -q . && printf '%s\n' "$2" > VERSION && git add VERSION ) >/dev/null 2>&1
}
add() {     # add <dir> <relpath> <content>   -- `git add` is enough; git grep reads the index
    mkdir -p "$(dirname -- "$1/$2")"
    printf '%s\n' "$3" > "$1/$2"
    ( cd "$1" && git add -- "$2" ) >/dev/null 2>&1
}
says() {    # says <name> <yes|no> <pattern> -- judge the LAST run's output
    name=$1; want=$2; pat=$3
    if grep -q -- "$pat" "$work/out"; then got=yes; else got=no; fi
    if [ "$got" = "$want" ]; then
        printf '  ok    %-56s said=%s\n' "$name" "$got"
    else
        printf '  FAIL  %-56s said=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$work/out"
        fails=$((fails + 1))
    fi
}
run() {     # run <name> <expected-rc> <dir> [args...]
    name=$1; want=$2; dir=$3; shift 3
    cases=$((cases + 1))
    # red-proved: the case in which the gate returned non-zero on a perturbed input.
    if [ "$want" != 0 ]; then red=$((red + 1)); fi
    case " $* " in *" --list "*) ;; *) set -- --arms floors "$@" ;; esac
    ( cd / && REPO_ROOT="$dir" bash "$subject" "$@" ) > "$work/out" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-56s rc=%s\n' "$name" "$got"
    else
        printf '  FAIL  %-56s rc=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$work/out"
        fails=$((fails + 1))
    fi
}

# case_1 -- the line that shipped: the SDK example floored a whole major below
# the package it is built against. This is the case the gate exists for.
d=$work/case_1; mkrepo "$d" 5.0.0
add "$d" examples/sdk/CMakeLists.txt 'find_package(LibreMiddleware 4.0 REQUIRED CONFIG)'
run "case_1 floor a major below VERSION" 1 "$d"

# case_2 -- a floor ABOVE VERSION is exactly as unsatisfiable under
# SameMajorVersion, so ">=" would be the wrong comparison.
d=$work/case_2; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'find_package(LibreAgent 6.0 REQUIRED CONFIG)'
run "case_2 floor a major above VERSION" 1 "$d"

# case_3 -- the happy path, so a gate that fails everything cannot pass this.
d=$work/case_3; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'find_package(LibreMiddleware 5.0 REQUIRED CONFIG)'
run "case_3 agreeing floor" 0 "$d"

# case_4 -- the VERSION_RANGE shape that shipped in the consumer docs. Its
# floor is the FIRST token; a scanner that reads the last one calls 4.1...<5.0
# a 5.x floor and passes the worst line in the document.
d=$work/case_4; mkrepo "$d" 5.0.0
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 4.1...<5.0 REQUIRED CONFIG)'
run "case_4 range floor reads the low end" 1 "$d"

# case_5 -- the same shape with the low end inside the major. This fixture has
# no project() name, so LibreMiddleware is a FOREIGN package here and only the
# major is comparable; case_19 is the same line in the repository that publishes
# that package, where it is a failure.
d=$work/case_5; mkrepo "$d" 5.0.0
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
run "case_5 range floor inside the major, foreign package" 0 "$d"

# case_6 -- `4.x`. A `git grep 4.2` sweep does not see this and neither does a
# scanner that insists on three numeric components.
d=$work/case_6; mkrepo "$d" 5.0.0
add "$d" cmake/GitVersion.cmake '# breaks find_package(LibreMiddleware 4.x CONFIG) at configure time'
run "case_6 the 4.x shape" 1 "$d"

# case_7 -- CHANGELOG.md is a historical record. "a find_package(LibreAgent 4.2
# ...) floor no longer applies" is a true sentence about a past release and
# must not fail the gate, or the release note that removes a floor becomes the
# reason the gate is red.
d=$work/case_7; mkrepo "$d" 5.0.0
add "$d" CHANGELOG.md '- a `find_package(LibreAgent 4.2 ...)` floor no longer applies'
run "case_7 CHANGELOG is exempt" 0 "$d"

# case_8 -- vendored code carries its own versions.
d=$work/case_8; mkrepo "$d" 5.0.0
add "$d" thirdparty/foo/CMakeLists.txt 'find_package(LibreMiddleware 4.0 REQUIRED CONFIG)'
run "case_8 thirdparty is exempt" 0 "$d"

# case_9 -- a bare call carries no floor and must not be invented into one.
d=$work/case_9; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'find_package(LibreMiddleware REQUIRED CONFIG)'
run "case_9 a versionless call is not a floor" 0 "$d"

# case_10 -- find_dependency() inside a Config package is the same contract
# under a different verb.
d=$work/case_10; mkrepo "$d" 5.0.0
add "$d" cmake/Config.cmake.in 'find_dependency(LibreMiddleware 4.2 REQUIRED CONFIG)'
run "case_10 find_dependency counts" 1 "$d"

# case_11 -- the vacuum. A repository whose scan matches nothing is not proved
# clean, it is unmeasured; --min says how many floors the caller knows exist.
d=$work/case_11; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" README.md 'no floors here at all'
run "case_11 no floors, --min 1, is a failure" 1 "$d" --min 1
run "case_11b no floors, no --min, is a pass"  0 "$d"

# case_12 -- not a git checkout: the scan cannot run, and "cannot judge" must
# not be spelled the same as "clean".
d=$work/case_12; mkdir -p "$d"; printf '5.0.0\n' > "$d/VERSION"
run "case_12 outside a git checkout is rc=2, not a pass" 2 "$d"

# case_13 -- VERSION unreadable: same rule, the gate must refuse to judge.
d=$work/case_13; mkrepo "$d" 5.0.0
rm -f "$d/VERSION"
add "$d" CMakeLists.txt 'find_package(LibreMiddleware 4.0 REQUIRED CONFIG)'
run "case_13 no VERSION is rc=2, not a pass" 2 "$d"

# case_14 -- two calls on one line; a scanner that stops at the first match
# passes the second one.
d=$work/case_14; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'find_package(LibreAgent 5.0 CONFIG) find_package(LibreMiddleware 4.0 CONFIG)'
run "case_14 second call on the same line is seen" 1 "$d"

# case_15 -- the gate no longer lives in the tree it judges, so its own
# fixtures (this self-test carries wrong floors on purpose) must not be what it
# reads: run from the gates checkout, REPO_ROOT decides. A clean fixture is
# green although the gate's own directory is full of wrong floors, and the same
# fixture with one wrong floor is red -- reading the wrong tree could only get
# one of the two right.
d=$work/case_15; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'find_package(LibreMiddleware 5.0 REQUIRED CONFIG)'
cases=$((cases + 1))
( cd "$here" && GITHUB_WORKSPACE="$here/.." REPO_ROOT="$d" bash "$subject" --arms floors ) > "$work/out" 2>&1
[ "$?" = 0 ] && printf '  ok    %-56s rc=0\n' "case_15 run from the gates checkout, clean fixture" \
    || { printf '  FAIL  %-56s\n' "case_15 run from the gates checkout, clean fixture"; sed 's/^/          /' "$work/out"; fails=$((fails + 1)); }
add "$d" src/CMakeLists.txt 'find_package(LibreAgent 4.0 REQUIRED CONFIG)'
cases=$((cases + 1)); red=$((red + 1))
( cd "$here" && GITHUB_WORKSPACE="$here/.." REPO_ROOT="$d" bash "$subject" --arms floors ) > "$work/out" 2>&1
[ "$?" = 1 ] && printf '  ok    %-56s rc=1\n' "case_15b ... and the same fixture with a wrong floor" \
    || { printf '  FAIL  %-56s\n' "case_15b ... and the same fixture with a wrong floor"; sed 's/^/          /' "$work/out"; fails=$((fails + 1)); }

# case_16 -- the window a major bump opens: this repository is still on 5, the
# package it floors against has already moved to 6. Without saying so the tree
# is a failure; naming the expectation per package describes it instead. Both
# halves are asserted, because an override that made everything green would be
# a way of not running the gate.
d=$work/case_16; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'find_package(LibreMiddleware 6.0 REQUIRED CONFIG)'
add "$d" cmake/Config.cmake.in 'find_dependency(LibreAgent 5.0 REQUIRED CONFIG)'
run "case_16 mixed majors without an override is a failure" 1 "$d"
LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=6"; export LIBRESCRS_FLOOR_MAJOR
run "case_16b the same tree, expectation keyed per package" 0 "$d"
unset LIBRESCRS_FLOOR_MAJOR

# case_17 -- the override names one package and must not cover the others: a
# blanket skip and a per-package expectation are the same green otherwise.
d=$work/case_17; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'find_package(LibreMiddleware 6.0 REQUIRED CONFIG)'
add "$d" src/CMakeLists.txt 'find_package(LibreCelik 4.0 REQUIRED CONFIG)'
LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=6"; export LIBRESCRS_FLOOR_MAJOR
run "case_17 an override for one package covers only that one" 1 "$d"
unset LIBRESCRS_FLOOR_MAJOR

# case_18 -- an override nobody can parse is not an override; refusing to judge
# is rc=2, never a pass.
d=$work/case_18; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'find_package(LibreMiddleware 5.0 REQUIRED CONFIG)'
LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=six"; export LIBRESCRS_FLOOR_MAJOR
run "case_18 an unparsable override is rc=2, not a pass" 2 "$d"
unset LIBRESCRS_FLOOR_MAJOR

# case_19 -- the line that shipped in the consumer guide: a minor pin whose low
# end is above the version this repository installs. Its major agrees, so a gate
# comparing majors calls it clean, and the generated SameMajorVersion file
# refuses it anyway. Measured against a real install: `5.1...<6.0` against 5.0.0
# is "no configuration file compatible with requested version range".
d=$work/case_19; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
run "case_19 a minor pin above what this repository ships" 1 "$d"

# case_20 -- the satisfiable spelling of the same recipe, so a gate that failed
# every range would pass case_19 for the wrong reason.
d=$work/case_20; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.0...<6.0 REQUIRED CONFIG)'
run "case_20 a minor pin the shipped package satisfies" 0 "$d"

# case_21 -- the limit, asserted rather than assumed: a minor pin on ANOTHER
# component cannot be judged here, because this checkout does not know that
# component's minor. Turning this into a failure would make every lockstep
# window red for a floor that is correct.
d=$work/case_21; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" src/CMakeLists.txt 'find_package(LibreAgent 5.4 REQUIRED CONFIG)'
run "case_21 a minor pin on another component is not judged" 0 "$d"

# case_22 -- a per-package override naming a DIFFERENT major says the shipped
# version is not what VERSION says, so the whole-version comparison must stand
# down with the major one. case_23b is the spelling that says nothing new.
d=$work/case_22; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 6.1...<7.0 REQUIRED CONFIG)'
run "case_22 without the override the pin is a failure" 1 "$d"
LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=6"; export LIBRESCRS_FLOOR_MAJOR
run "case_22b the override covers the whole comparison" 0 "$d"
unset LIBRESCRS_FLOOR_MAJOR

# case_23 -- an override that REPEATS the major already in VERSION contradicts
# nothing, so it must not make the whole-version comparison disappear. It did:
# the expectation was read before VERSION was, and any spelling of the override
# switched the comparison off with the ordinary green line. An env var that
# removes a check without saying so is a way of not running the gate.
d=$work/case_23; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
LIBRESCRS_FLOOR_MAJOR="5"; export LIBRESCRS_FLOOR_MAJOR
run "case_23 repeating VERSION's own major is not a change" 1 "$d"
unset LIBRESCRS_FLOOR_MAJOR
LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=5"; export LIBRESCRS_FLOOR_MAJOR
run "case_23b the per-package spelling of the same non-change" 1 "$d"
unset LIBRESCRS_FLOOR_MAJOR

# case_24 -- the other half: an override naming a DIFFERENT major does say
# VERSION is not the shipped truth, so there the comparison must stand down --
# in the bare spelling too, not only the per-package one case_22b covers.
d=$work/case_24; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 6.1...<7.0 REQUIRED CONFIG)'
LIBRESCRS_FLOOR_MAJOR="6"; export LIBRESCRS_FLOOR_MAJOR
run "case_24 a bare override on another major stands it down" 0 "$d"
# and it must say so: a comparison that disappears without a word is the shape
# this gate was written against.
says "case_24b the stand-down names itself" yes "compared by major only"
unset LIBRESCRS_FLOOR_MAJOR
run  "case_24c without the override the same tree is a failure" 1 "$d"
says "case_24d ... and nothing was stood down" no "compared by major only"

# case_25 -- a range has two ends and the generated ConfigVersion file checks
# both. This is the drift shape: a range written correctly at 5.0 goes
# unsatisfiable the day VERSION reaches 5.1, with no digit in the line changing
# and its major still agreeing. Asserted at both VERSIONs so a gate that failed
# every range could not pass the second half.
d=$work/case_25; mkrepo "$d" 5.1.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.1.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.0...<5.1 REQUIRED CONFIG)'
run "case_25 a range whose top excludes what this tree ships" 1 "$d"
d=$work/case_25b; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.0...<5.1 REQUIRED CONFIG)'
run "case_25b the same line while the tree still ships 5.0.0" 0 "$d"

# case_26 -- the inclusive spelling of a range excludes by being BELOW the
# shipped version rather than equal to it, which is a different comparison.
d=$work/case_26; mkrepo "$d" 5.1.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.1.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.0...5.0 REQUIRED CONFIG)'
run "case_26 an inclusive range ending below what we ship" 1 "$d"

# case_27 -- the limit again, on the upper bound this time: another component's
# range cannot be judged here either, for the same reason case_21 gives.
d=$work/case_27; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" src/CMakeLists.txt 'find_package(LibreAgent 5.0...<5.0 REQUIRED CONFIG)'
run "case_27 another component's range top is not judged" 0 "$d"

# case_28 -- the top of a range has a major rule of its own, on top of the value
# one case_25/case_26 cover: an inclusive top must stay inside the installed
# major, an exclusive top may reach the next major exactly and no further. Both
# shapes below floor at 5.0 and lead with the agreeing major, so nothing but the
# top end distinguishes them from the recipe the guide ships. Measured against a
# real install of 5.0.0: `5.0...6.0` and `5.0...<7.0` are refused, `5.0...<6.0`
# (case_20) and `5.0...5.9` (case_28d) configure.
d=$work/case_28; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.0...6.0 REQUIRED CONFIG)'
run  "case_28 an inclusive top in the next major" 1 "$d"
says "case_28b ... and the message names the line it left" yes "outside the major 5 line"
d=$work/case_28c; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.0...<7.0 REQUIRED CONFIG)'
run "case_28c an exclusive top past the next major" 1 "$d"
d=$work/case_28d; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.0...5.9 REQUIRED CONFIG)'
run "case_28d an inclusive top inside the major is satisfiable" 0 "$d"
# ... and the same limit as case_21/case_27: another component's top is not ours
# to judge, so a gate failing every high end could not pass this.
d=$work/case_28e; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" src/CMakeLists.txt 'find_package(LibreAgent 5.0...7.0 REQUIRED CONFIG)'
run "case_28e another component's top is not judged" 0 "$d"

# case_29 -- inspection mode and check mode must not tell a reader different
# things about the same line: the --list row for a floor the check rejects
# carries that verdict, instead of a bare "major 5 expected 5".
d=$work/case_29; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
run  "case_29 --list is inspection, so it still exits 0" 0 "$d" --list
says "case_29b --list names the verdict the check reaches" yes "UNSATISFIABLE"
run  "case_29c the same tree in check mode is a failure" 1 "$d"
d=$work/case_29d; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.0...<6.0 REQUIRED CONFIG)'
run  "case_29d a satisfiable floor lists clean" 0 "$d" --list
says "case_29e ... and carries no verdict marker" no "UNSATISFIABLE"

# case_30 -- the whole-floor comparison rests on a package name read from
# `project()`. Without it the check falls back to the major-only one it replaced
# and says so on stderr -- a comparison disappearing while the job stays green,
# which is the shape this gate exists to remove. `--min` is the caller saying
# this repository IS meant to be measurable, so there the fallback is rc=2. The
# floor below is the one case_19 fails on, so the fixture is only green while the
# comparison is absent.
d=$work/case_30; mkrepo "$d" 5.0.0
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
run  "case_30 no project() under --min is rc=2, not a pass" 2 "$d" --min 1
says "case_30b ... and names what could not be set up" yes "could not be set up"
# Without --min the note stands and the run is green: a checkout with no CMake
# build publishes no package of its own, and the cross-repository check that
# delegates to this gate from such a repository must not be failing it for
# lacking something it never had.
run  "case_30c the same tree without --min keeps the note" 0 "$d"
says "case_30d ... and the note is the reason it is green" yes "compared by major only"
# The control: the identical floor with a project() line to compare it against.
d=$work/case_30e; mkrepo "$d" 5.0.0
add "$d" CMakeLists.txt 'project(LibreMiddleware VERSION 5.0.0 LANGUAGES CXX)'
add "$d" docs/CONSUMERS.md 'find_package(LibreMiddleware 5.1...<6.0 REQUIRED CONFIG)'
run "case_30e with project() the same floor is judged whole" 1 "$d" --min 1


echo "-- stamp arm"
# $1 dir, $2 module flavour: newer-wins | tag-wins | no-git
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

# $1 label, $2 expected rc, $3 dir
expect() {
    cases=$((cases + 1))
    # red-proved: the case in which the gate returned non-zero on a perturbed input.
    if [ "$2" != 0 ]; then red=$((red + 1)); fi
    out="$( (cd / && REPO_ROOT="$3" bash "$GATE" --arms stamp) 2>&1 )"
    rc=$?
    if [ "$rc" != "$2" ]; then
        echo "FAIL: $1 -- expected rc=$2, got rc=$rc"
        printf '%s\n' "$out" | sed 's/^/       /'
        fails=$((fails + 1))
    fi
}

# case_1 -- the shape the project ships: the file version wins when the tag is
# behind, the tag wins when it is ahead.
d="$WORK/c1"; mkdir -p "$d"; module "$d" newer-wins; project_file "$d"; echo 5.0.0 > "$d/VERSION"
expect case_1_newer_wins 0 "$d"

# case_2 -- the defect: describe decides unconditionally, so a tag a major
# behind stamps the old major over a bumped VERSION. This is the case that was
# live in a shipped tree with every other gate green.
d="$WORK/c2"; mkdir -p "$d"; module "$d" tag-wins; project_file "$d"; echo 5.0.0 > "$d/VERSION"
expect case_2_stale_tag_wins 1 "$d"

# case_3 -- the over-correction: git ignored altogether, so a tag AHEAD of
# VERSION (a release commit, a hotfix branch) is stamped as the old version.
# A one-sided gate would call this clean.
d="$WORK/c3"; mkdir -p "$d"; module "$d" no-git; project_file "$d"; echo 5.0.0 > "$d/VERSION"
expect case_3_tag_ahead_ignored 1 "$d"

# case_4 -- no VERSION file: there is no expected major, so there is no verdict.
d="$WORK/c4"; mkdir -p "$d"; module "$d" newer-wins; project_file "$d"
expect case_4_no_version_file 2 "$d"

# case_5 -- VERSION carries no numeric major.
d="$WORK/c5"; mkdir -p "$d"; module "$d" newer-wins; project_file "$d"; echo "unreleased" > "$d/VERSION"
expect case_5_unparsable_version 2 "$d"

# case_6 -- nothing to configure.
d="$WORK/c6"; mkdir -p "$d"; echo 5.0.0 > "$d/VERSION"
expect case_6_no_cmakelists 2 "$d"

# case_7 -- the configure dies before project(), so the probe never records a
# stamp. "Could not measure" must not be spelled the same as "measured, clean".
d="$WORK/c7"; mkdir -p "$d"; module "$d" newer-wins; echo 5.0.0 > "$d/VERSION"
{
    echo 'cmake_minimum_required(VERSION 3.24)'
    echo 'message(FATAL_ERROR "fixture: dies before project()")'
} > "$d/CMakeLists.txt"
expect case_7_probe_never_reached 2 "$d"


echo "-- surfaces arm"
out="$work/out"
run() {   # run <name> <expected-rc> <dir> [VAR=VAL ...]
    name=$1; want=$2; dir=$3; shift 3
    cases=$((cases + 1))
    # red-proved: the case in which the gate returned non-zero on a perturbed input.
    if [ "$want" != 0 ]; then red=$((red + 1)); fi
    ( cd / && env REPO_ROOT="$dir" "$@" bash "$subject" --arms surfaces ) > "$out" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-58s rc=%s\n' "$name" "$got"
    else
        printf '  FAIL  %-58s rc=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$out"
        fails=$((fails + 1))
    fi
}

says() {  # says <name> <pattern>  -- about the last run
    if grep -q -- "$2" "$out"; then
        printf '  ok    %-58s\n' "$1"
    else
        printf '  FAIL  %-58s (no match: %s)\n' "$1" "$2"
        sed 's/^/          /' "$out"
        fails=$((fails + 1))
    fi
}

# A fixture repo: VERSION 5.0.0, one CMake project, one Plasma metadata, one
# XML plist and one xcodegen spec -- one of every kind the script knows.
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

# case_1 -- everything agrees. Without it a check that fails everything passes
# every other case in this file.
d=$work/case_1; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
run "case_1 every surface agrees" 0 "$d"
says "case_1 all four surfaces were counted" 'all 4 version surface(s) state 5.0.0'
says "case_1 CFBundleVersion 1 is not read as the version" '  -> app/Info.plist (CFBundleShortVersionString) states 5.0.0'
says "case_1 X-Plasma-API-Minimum-Version is not read as the version" '  -> pkg/metadata.json (KPlugin.Version) states 5.0.0'

# case_2 -- the shipped bug: project() stamps its own literal while VERSION and
# every packaging recipe say 5.0.0.
d=$work/case_2; fixture "$d" 0.1.0 5.0.0 5.0.0 5.0.0
run "case_2 project() stamps something else" 1 "$d"
says "case_2 the message names project()" "project(Fixture) in . states '0.1.0'"

# case_3 -- the applet metadata is installed verbatim, so a stale literal there
# is what Plasma shows even when the build stamp is right.
d=$work/case_3; fixture "$d" 5.0.0 0.1.0 5.0.0 5.0.0
run "case_3 applet metadata states something else" 1 "$d"
says "case_3 the message names metadata.json" "pkg/metadata.json (KPlugin.Version) states '0.1.0'"

# case_4 -- the plist half, which is what Finder, mdls and About windows read.
d=$work/case_4; fixture "$d" 5.0.0 5.0.0 0.1 5.0.0
run "case_4 plist states something else" 1 "$d"
says "case_4 the message names the plist" "app/Info.plist (CFBundleShortVersionString) states '0.1'"

# case_5 -- the xcodegen spec, which is UPSTREAM of the generated plist:
# editing the plist alone is undone by the next `xcodegen generate`.
d=$work/case_5; fixture "$d" 5.0.0 5.0.0 5.0.0 0.1.0
run "case_5 xcodegen spec states something else" 1 "$d"
says "case_5 the message names project.yml" "project.yml (CFBundleShortVersionString) states '0.1.0'"

# case_6 -- a configure_file() that never ran leaves the placeholder in the file
# that gets installed. It is unequal for a different reason, so it says so.
d=$work/case_6; fixture "$d" 5.0.0 '@PROJECT_VERSION@' 5.0.0 5.0.0
run "case_6 unexpanded placeholder in the installed file" 1 "$d"
says "case_6 the message names the placeholder" 'still holds the literal @PROJECT_VERSION@'

# case_7 -- a tree that HAS moved to configure_file must stay green, or this
# check becomes the reason nobody makes that move.
d=$work/case_7; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
sed 's/"Version": "5.0.0"/"Version": "@PROJECT_VERSION@"/' "$d/pkg/metadata.json" > "$d/pkg/metadata.json.in"
rm "$d/pkg/metadata.json"
run "case_7 template form is accepted" 0 "$d"

# case_8 -- nothing to compare against is not a pass.
d=$work/case_8; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; rm "$d/VERSION"
run "case_8 no VERSION file is undecidable, not green" 2 "$d"

# case_9 -- an empty surface list is the vacuum case: every surface agreed
# because none was named.
d=$work/case_9; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
printf '# nothing listed\n' > "$d/ci/version-surfaces.txt"
run "case_9 an empty surface list is undecidable, not green" 2 "$d"

# case_10 -- a missing surface list, likewise.
d=$work/case_10; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; rm "$d/ci/version-surfaces.txt"
run "case_10 a missing surface list is undecidable" 2 "$d"

# case_11 -- a surface kind nobody implements must stop the run, not be skipped
# silently: a typo in the list would otherwise remove a surface from the gate.
d=$work/case_11; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
printf 'plist-shortversion  app/Info.plist\n' > "$d/ci/version-surfaces.txt"
run "case_11 an unknown surface kind is undecidable" 2 "$d"

# case_12 -- a listed file that does not exist is undecidable, not green: a
# path typo would otherwise drop the surface.
d=$work/case_12; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
printf 'plist-short-version  app/Gone.plist\n' > "$d/ci/version-surfaces.txt"
run "case_12 a listed file that is missing is undecidable" 2 "$d"

# case_13 -- no cmake on the runner is not a pass. This is the one that would
# otherwise turn the gate green on exactly the machines where it broke.
d=$work/case_13; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
run "case_13 no cmake is undecidable, not green" 2 "$d" CMAKE=/nonexistent/cmake

# case_14 -- a configure that dies BEFORE project() reports no version at all.
d=$work/case_14; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
printf 'cmake_minimum_required(VERSION 3.24.0 FATAL_ERROR)\nmessage(FATAL_ERROR "died early")\n' > "$d/CMakeLists.txt"
run "case_14 configure dies before project() is undecidable" 2 "$d"

# case_15 -- a CMakeLists with no project(VERSION) at all: CMake still fires
# the hook, with an implicit project(Project) carrying no version. Blaming the
# tree for "states ''" would hide this check's own blind spot.
d=$work/case_15; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
printf 'cmake_minimum_required(VERSION 3.24.0 FATAL_ERROR)\nproject(Fixture LANGUAGES NONE)\n' > "$d/CMakeLists.txt"
run "case_15 project() with no VERSION is undecidable" 2 "$d"

# case_16 -- a leading v in VERSION is the same version, as elsewhere in this
# repo's tooling (check-release-lockstep.sh strips it too).
d=$work/case_16; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0; printf 'v5.0.0\n' > "$d/VERSION"
run "case_16 a v-prefixed VERSION is the same version" 0 "$d"

# case_17 -- the plist half of the same move. A .plist.in states no number of
# its own, so what makes it measurable is the cmake-project surface standing
# beside it in the list: that one reads the number the build really stamps,
# which is the number configure_file() would fill in here.
d=$work/case_17; fixture "$d" 5.0.0 5.0.0 '@PROJECT_VERSION@' 5.0.0
mv "$d/app/Info.plist" "$d/app/Info.plist.in"
printf '# <kind> <path>\ncmake-project        .\nplist-short-version  app/Info.plist.in\n' \
    > "$d/ci/version-surfaces.txt"
run "case_17 a plist template beside a measured surface is accepted" 0 "$d"

# case_18 -- the .in suffix is not a licence to stop checking: a literal inside
# a template is still a hand-typed number, and it is still compared against
# VERSION. Without this case, "accept anything ending in .in" passes case_17.
d=$work/case_18; fixture "$d" 5.0.0 5.0.0 4.9.9 5.0.0
mv "$d/app/Info.plist" "$d/app/Info.plist.in"
printf '# <kind> <path>\ncmake-project        .\nplist-short-version  app/Info.plist.in\n' \
    > "$d/ci/version-surfaces.txt"
run "case_18 a literal inside a plist template is still refused" 1 "$d"

# case_19 -- a template with nothing measuring the build is the vacuum case
# again: every surface would be a placeholder and the gate would compare
# nothing to VERSION. That is "I could not judge", not a pass.
d=$work/case_19; fixture "$d" 5.0.0 5.0.0 '@PROJECT_VERSION@' 5.0.0
mv "$d/app/Info.plist" "$d/app/Info.plist.in"
printf '# <kind> <path>\nplist-short-version  app/Info.plist.in\n' \
    > "$d/ci/version-surfaces.txt"
run "case_19 a plist template with no measured surface is undecidable" 2 "$d"

# case_20 -- the branch above is bound to the .in SUFFIX, not to the placeholder:
# a plain plist holding @PROJECT_VERSION@ is a configure_file() that never ran,
# and it is still a mismatch. Without this case the suffix test could be dropped
# and the placeholder would be accepted in the file that actually ships.
d=$work/case_20; fixture "$d" 5.0.0 5.0.0 '@PROJECT_VERSION@' 5.0.0
printf '# <kind> <path>\ncmake-project        .\nplist-short-version  app/Info.plist\n' \
    > "$d/ci/version-surfaces.txt"
run "case_20 the placeholder in a plain plist is still a mismatch" 1 "$d"

# case_21 -- a template states no number of its own; "all N agree" must not
# quietly fold those N in as if each one had stated the version itself.
d=$work/case_21; fixture "$d" 5.0.0 5.0.0 5.0.0 5.0.0
sed 's/"Version": "5.0.0"/"Version": "@PROJECT_VERSION@"/' "$d/pkg/metadata.json" > "$d/pkg/metadata.json.in"
rm "$d/pkg/metadata.json"
run "case_21 summary counts the templated surface" 0 "$d"
says "case_21 summary names how many were read from a template" '1 read the number'

# --- packaging metadata ------------------------------------------------------
# A package fixture: VERSION 5.0.0, a Debian changelog, an RPM spec, and a shell
# helper the packaging scripts source to name what they build.
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

# case_22 -- the Debian changelog names another upstream version: dpkg would
# build a package labelled one version around a tree that says another.
d=$work/case_22; pkgfixture "$d" 4.2.0-1 5.0.0 5.0.0
run "case_22 debian changelog states another version" 1 "$d"
says "case_22 the message names both versions" "packaging/debian/changelog (Debian version) states '4.2.0' but VERSION says '5.0.0'"
says "case_22 the message names the generator" "regenerate packaging/debian/changelog with ci/scripts/changelog-to-debian.sh"

# case_23 -- the same version with a Debian revision agrees: the revision is
# the packaging's own counter, not the upstream version.
d=$work/case_23; pkgfixture "$d" 5.0.0-1 5.0.0 5.0.0
run "case_23 debian changelog 5.0.0-1 agrees with 5.0.0" 0 "$d"
says "case_23 all three packaging surfaces were counted" 'all 3 version surface(s) state 5.0.0'

# case_24 -- the RPM spec names another version.
d=$work/case_24; pkgfixture "$d" 5.0.0-1 4.2.0 5.0.0
run "case_24 rpm spec Version: states another version" 1 "$d"
says "case_24 the message names the spec" "packaging/rpm/fixture.spec (Version:) states '4.2.0'"

# case_25 -- the RPM spec agrees (covered by case_23 too, asserted on its own
# so a kind that ignores the spec cannot hide behind the Debian row).
d=$work/case_25; pkgfixture "$d" 5.0.0-1 5.0.0 5.0.0
printf '# <kind> <path>\nrpm-spec-version     packaging/rpm/fixture.spec\n' > "$d/ci/version-surfaces.txt"
run "case_25 rpm spec Version: agrees" 0 "$d"

# case_26 -- the shell helper names the artefacts; an older number there is an
# AppImage and a DMG labelled with the previous release.
d=$work/case_26; pkgfixture "$d" 5.0.0-1 5.0.0 4.2.0
run "case_26 shell helper prints an older version" 1 "$d"
says "case_26 the message names the helper" "scripts/project-version.sh (project_version) states '4.2.0'"

# case_27 -- a list naming none of these rows at all is the vacuum case for the
# new kinds as much as for the old ones.
d=$work/case_27; pkgfixture "$d" 5.0.0-1 5.0.0 5.0.0
printf '# <kind> <path>\n' > "$d/ci/version-surfaces.txt"
run "case_27 a packaging list with no rows is undecidable" 2 "$d"

# case_28 -- the helper must be asked with an ABSOLUTE root, the way both of
# its production callers ask it. Its guard compares the argument with git's
# toplevel, so a relative "." never matches, the newest tag is skipped and the
# VERSION file answers: the right number for the wrong reason. Here the tag
# says 4.2.0 and VERSION 5.0.0, so only an absolute call sees the defect.
d=$work/case_28; pkgfixture "$d" 5.0.0-1 5.0.0 5.0.0
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
run "case_28 the helper is judged through an absolute root" 1 "$d"
says "case_28 the older tag is what it reports" "states '4.2.0'"


echo "-- the merged gate"
run() {  # run <name> <expected-rc> <dir> [args...]
    name=$1; want=$2; dir=$3; shift 3
    cases=$((cases + 1))
    if [ "$want" != 0 ]; then red=$((red + 1)); fi
    ( cd / && REPO_ROOT="$dir" bash "$subject" "$@" ) > "$work/out" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-58s rc=%s\n' "$name" "$got"
    else
        printf '  FAIL  %-58s rc=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$work/out"
        fails=$((fails + 1))
    fi
}
says() {  # says <name> <pattern> -- about the last run
    if grep -q -- "$2" "$work/out"; then printf '  ok    %-58s\n' "$1"
    else printf '  FAIL  %-58s (no match: %s)\n' "$1" "$2"; sed 's/^/          /' "$work/out"; fails=$((fails + 1)); fi
}
# A whole tree, every arm green: a CMake project whose version module follows
# VERSION, a changelog section, an agreeing floor and one surface.
whole() {  # whole <dir>
    d=$1; mkrepo "$d" 5.0.0; module "$d" newer-wins; project_file "$d"
    printf '# Changelog\n\n## [Unreleased] — 5.0.0\n\n- entry\n' > "$d/CHANGELOG.md"
    mkdir -p "$d/ci"; printf 'rpm-spec-version  pkg.spec\n' > "$d/ci/version-surfaces.txt"
    printf 'Name: x\nVersion: 5.0.0\n' > "$d/pkg.spec"
    add "$d" src/CMakeLists.txt 'find_package(LibreAgent 5.0 REQUIRED CONFIG)'
}
d=$work/m1; whole "$d"
run "M1 every arm agrees on a whole tree" 0 "$d"
says "M1 all four arms ran" "4 arm(s) run, verdict rc=0"
d=$work/m2; whole "$d"; add "$d" src/b.cmake 'find_package(LibreAgent 4.0 REQUIRED CONFIG)'
run "M2 one arm red makes the gate red" 1 "$d"
says "M2 the red arm is named" "floors rc=1"
d=$work/m3; whole "$d"; rm "$d/ci/version-surfaces.txt"
run "M3 one arm unmeasurable, the rest green, is rc=2" 2 "$d"
d=$work/m4; whole "$d"; rm "$d/ci/version-surfaces.txt"; add "$d" src/b.cmake 'find_package(LibreAgent 4.0 REQUIRED CONFIG)'
run "M4 a red arm outranks an unmeasurable one" 1 "$d"
d=$work/m1
run "M5 an unknown arm is rc=2, not a skipped arm" 2 "$d" --arms lockstep,flors
run "M6 an arm named twice" 2 "$d" --arms lockstep,lockstep
run "M7 an empty arm list" 2 "$d" --arms ''
run "M8 --version overrides VERSION for the lockstep" 1 "$d" --arms lockstep --version 5.0.1
run "M9 an unknown option" 2 "$d" --frobnicate
cases=$((cases + 1)); red=$((red + 1))
( cd / && env -u REPO_ROOT -u GITHUB_WORKSPACE bash "$subject" ) > "$work/out" 2>&1
[ "$?" = 2 ] && printf '  ok    %-58s rc=2\n' "M10 no consumer tree at all" \
    || { printf '  FAIL  %-58s\n' "M10 no consumer tree at all"; fails=$((fails + 1)); }
cases=$((cases + 1))
( cd / && GITHUB_WORKSPACE="$work/m2" REPO_ROOT="$work/m1" bash "$subject" ) > "$work/out" 2>&1
[ "$?" = 0 ] && printf '  ok    %-58s rc=0\n' "M11 REPO_ROOT wins over a (red) workspace" \
    || { printf '  FAIL  %-58s\n' "M11 REPO_ROOT wins over a (red) workspace"; fails=$((fails + 1)); }

if [ "$fails" -eq 0 ]; then
    echo "check-version selftest: all $cases cases passed"
    printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
    exit 0
fi
echo "check-version selftest: $fails of $cases case(s) failed"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit 1
