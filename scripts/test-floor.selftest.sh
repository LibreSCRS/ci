#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# test-floor.selftest.sh -- a real CMake build dir (no compiler: project NONE,
# tests registered against stub executables), judged by test-floor.py. The
# red cases are the losses the floor exists for: one test of a binary gone,
# a whole binary gone, and every "this is not a test set" shape.
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GATE="$here/test-floor.py"
command -v cmake >/dev/null 2>&1 && command -v ctest >/dev/null 2>&1 \
    || { echo "FATAL: cmake/ctest not on PATH -- cannot judge" >&2; exit 2; }
T="$(mktemp -d "/var/tmp/test-floor-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
out="$T/out"
cases=0 red=0 fails=0

expect() {  # expect <label> <want-rc> <got-rc> <needle>...
    local label=$1 want=$2 got=$3 ok=0 n
    shift 3
    cases=$((cases + 1))
    [ "$want" = 0 ] || red=$((red + 1))
    [ "$got" = "$want" ] || ok=1
    for n in "$@"; do grep -qF -- "$n" "$out" || ok=1; done
    if [ "$ok" = 0 ]; then
        printf 'ok    %s (exit %s)\n' "$label" "$got"
    else
        printf 'FAIL  %s: wanted exit %s, got %s\n' "$label" "$want" "$got"
        sed 's/^/  | /' "$out"
        fails=1
    fi
}

# project <dir> <test-line>...: a consumer checkout whose build/ registers the
# given add_test() lines; ALPHA and BETA are stub binaries in the build dir.
project() {
    local d="$T/$1"
    shift
    rm -rf "$d"
    mkdir -p "$d/src" "$d/ci"
    {
        printf 'cmake_minimum_required(VERSION 3.20)\nproject(p NONE)\nenable_testing()\n'
        printf 'file(WRITE ${CMAKE_BINARY_DIR}/alpha_tests "#!/bin/sh\\n")\n'
        printf 'file(WRITE ${CMAKE_BINARY_DIR}/beta_tests "#!/bin/sh\\n")\n'
        printf '%s\n' "$@"
    } > "$d/src/CMakeLists.txt"
    cmake -S "$d/src" -B "$d/build" >/dev/null 2>&1 || { echo "FATAL: cmake failed" >&2; exit 2; }
    printf '%s' "$d"
}
A='${CMAKE_BINARY_DIR}/alpha_tests'
B='${CMAKE_BINARY_DIR}/beta_tests'
three=("add_test(NAME A.one COMMAND $A --gtest_filter=A.one)"
       "add_test(NAME A.two COMMAND $A --gtest_filter=A.two)"
       "add_test(NAME B.one COMMAND $B)")
judge() { (cd "$T" && REPO_ROOT="$1" python3 "$GATE" "${@:2}") >"$out" 2>&1; echo $?; }

d=$(project ok "${three[@]}")
printf '# floor\nalpha_tests 2\nbeta_tests 1\n' > "$d/ci/test-floor.txt"
expect "1 every binary at its floor passes" 0 "$(judge "$d" build)" \
    "ok    alpha_tests: 2 >= 2" "ok    beta_tests: 1 >= 1"

(cd "$T" && REPO_ROOT="$d" python3 "$GATE" --print build) >"$out" 2>&1
expect "2 --print writes the counts as a floor file" 0 "$?" "alpha_tests 2" "beta_tests 1"

d=$(project lost1 "${three[0]}" "${three[2]}")
printf 'alpha_tests 2\nbeta_tests 1\n' > "$d/ci/test-floor.txt"
expect "3 RED: one test of a binary lost" 1 "$(judge "$d" build)" "alpha_tests: 1 test(s), floor 2 -- 1 lost"

d=$(project lostbin "${three[0]}" "${three[1]}")
printf 'alpha_tests 2\nbeta_tests 1\n' > "$d/ci/test-floor.txt"
expect "4 RED: a whole binary no longer registered" 1 "$(judge "$d" build)" "beta_tests: the build registers no test"

d=$(project extra "${three[@]}")
printf 'alpha_tests 1\n' > "$d/ci/test-floor.txt"
expect "5 more tests than the floor, and an unlisted binary, pass" 0 "$(judge "$d" build)" \
    "note  beta_tests: 1 test(s), no floor"

d=$(project leg "${three[@]}")
printf 'beta_tests 1\n' > "$d/ci/test-floor.asan.txt"
expect "6 --floor names another file (one per leg)" 0 "$(judge "$d" --floor ci/test-floor.asan.txt build)" \
    "1 binary judged"
expect "7 no floor file cannot be judged" 2 "$(judge "$d" build)" "no floor file"

printf '# nothing\n' > "$d/ci/test-floor.txt"
expect "8 an empty floor file cannot be judged" 2 "$(judge "$d" build)" "names no binary"
printf 'alpha_tests two\n' > "$d/ci/test-floor.txt"
expect "9 a malformed line cannot be judged" 2 "$(judge "$d" build)" "is not <binary> <n>"
printf 'alpha_tests 1\nalpha_tests 2\n' > "$d/ci/test-floor.txt"
expect "10 a binary listed twice cannot be judged" 2 "$(judge "$d" build)" "listed twice"
printf 'alpha_tests 0\n' > "$d/ci/test-floor.txt"
expect "11 a floor of zero is no floor" 2 "$(judge "$d" build)" "n >= 1"

d=$(project none)
printf 'alpha_tests 1\n' > "$d/ci/test-floor.txt"
expect "12 a build that registers nothing cannot be judged" 2 "$(judge "$d" build)" "registers no test"

d=$(project nb "${three[@]}" "add_test(NAME alpha_tests_NOT_BUILT COMMAND $A)")
printf 'alpha_tests 2\n' > "$d/ci/test-floor.txt"
expect "13 a _NOT_BUILT test is a build that did not happen" 2 "$(judge "$d" build)" "_NOT_BUILT"

expect "14 a build dir that is not one cannot be judged" 2 "$(judge "$d" nowhere)" "no CTestTestfile.cmake"

mkdir -p "$T/nowhere"
(cd "$T/nowhere" && GIT_CEILING_DIRECTORIES="$T" python3 "$GATE" build) >"$out" 2>&1
expect "15 no checkout anywhere cannot be judged" 2 "$?" "no repository to judge"

[ "$fails" = 0 ] && echo "test-floor selftest: all cases behave" || echo "test-floor selftest: FAILED"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit "$fails"
