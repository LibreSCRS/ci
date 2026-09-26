#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# run-gates.selftest.sh -- the runner can fail, refuses what it cannot judge,
# and hands each gate the inputs it needs.
#
# The failure it exists to rule out is the silent green: a step whose gate
# list is empty or misspelt would otherwise "pass" by running nothing. Each of
# those is exit 2 here, by name. The happy path is proved against real gates
# over fixture checkouts, so a wrong argument order is a red case rather than
# a guess.
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY GITHUB_ACTIONS BUILD_DIR

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RG="$here/run-gates.py"
T="$(mktemp -d "/var/tmp/run-gates-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
out="$T/out"
fails=0
cases=0
red=0

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
        sed -n '1,15p' "$out" | sed 's/^/  | /'
        fails=1
    fi
}

# fixture <name>: a consumer checkout with one source file, clean.
fixture() {
    local d="$T/$1"
    mkdir -p "$d/ci" "$d/lib"
    printf 'int a;\n' > "$d/lib/a.cpp"
    git -C "$d" init -q
    git -C "$d" add -A
    git -C "$d" -c user.email=s@e -c user.name=s commit -qm f
    printf '%s' "$d"
}
commit() { git -C "$1" add -A && git -C "$1" -c user.email=s@e -c user.name=s commit -qm x; }
rg() {  # rg <root> <args...>: run for repository Consumer, from outside <root>
    (cd "$T" && REPO_ROOT="$1" python3 "$RG" --repo Consumer "${@:2}") >"$out" 2>&1
    echo $?
}

# --- refusing to judge
d=$(fixture r1)
expect "1 no gate named" 2 "$(rg "$d")" "no gate named"
expect "2 only blanks named" 2 "$(rg "$d" --gates '  ')" "no gate named"
expect "3 an unknown gate" 2 "$(rg "$d" --gates 'check-skip-reasons nonesuch')" \
    "unknown gate(s): nonesuch"
expect "4 a gate named twice" 2 "$(rg "$d" --gates 'check-skip-reasons check-skip-reasons')" \
    "named twice"
expect "5 a gate whose input is missing" 2 "$(rg "$d" --gates test-floor)" "need --build-dir"
mkdir -p "$T/nowhere"
(cd "$T/nowhere" && GIT_CEILING_DIRECTORIES="$T" python3 "$RG" --gates check-skip-reasons) \
    >"$out" 2>&1
expect "6 no checkout to judge" 2 "$?" "no repository to judge"

# --- running gates
d=$(fixture s1)
expect "7 a clean checkout passes the named gate" 0 "$(rg "$d" --gates check-skip-reasons)" \
    "1 gate(s), 1 passed, 0 failed, 0 could not judge"
printf 'TEST(S, T) { GTEST_SKIP(); }\n' > "$d/lib/t.cpp"; commit "$d"
expect "8 one gate red is red, and the others still run" 1 \
    "$(rg "$d" --gates 'check-skip-reasons check-version-lockstep')" \
    "2 gate(s), 0 passed, 1 failed, 1 could not judge"
d=$(fixture s2)
expect "9 a gate that cannot judge makes the run 'cannot judge'" 2 \
    "$(rg "$d" --gates 'check-skip-reasons check-version-lockstep')" \
    "1 passed, 0 failed, 1 could not judge"

# --- the root and the name from the CI environment
d=$(fixture s3)
printf 'TEST(S, T) { GTEST_SKIP(); }\n' > "$d/lib/t.cpp"; commit "$d"
(cd "$T" && GITHUB_WORKSPACE="$d" GITHUB_REPOSITORY=LibreSCRS/Consumer python3 "$RG" \
    --gates check-skip-reasons) >"$out" 2>&1
expect "10 GITHUB_WORKSPACE and GITHUB_REPOSITORY pick root and name" 1 "$?" "run-gates: Consumer:"
(cd "$T" && GITHUB_WORKSPACE="$T/s1" python3 "$RG" --root s3 --gates check-skip-reasons) \
    >"$out" 2>&1
expect "11 --root, relative to the working directory, wins over GITHUB_WORKSPACE" 1 "$?" \
    "lib/t.cpp"

# --- each gate gets its inputs
d=$(fixture b1)
mkdir -p "$d/build" "$d/bin"
: > "$d/build/CTestTestfile.cmake"
cat > "$d/bin/ctest" <<'CT'
#!/usr/bin/env bash
printf '{"tests":[{"name":"A.one","command":["/b/alpha_tests"]},{"name":"A.two","command":["/b/alpha_tests"]}]}\n'
CT
chmod +x "$d/bin/ctest"
printf 'alpha_tests 2\n' > "$d/ci/test-floor.txt"
printf 'alpha_tests 3\n' > "$d/ci/test-floor.asan.txt"; commit "$d"
(cd "$T" && PATH="$d/bin:$PATH" REPO_ROOT="$d" python3 "$RG" --gates test-floor \
    --build-dir build) >"$out" 2>&1
expect "12 test-floor gets the build dir" 0 "$?" "alpha_tests: 2 >= 2"
(cd "$T" && PATH="$d/bin:$PATH" REPO_ROOT="$d" python3 "$RG" --gates test-floor \
    --build-dir build --floor ci/test-floor.asan.txt) >"$out" 2>&1
expect "13 --floor picks the file, and a lost test is red" 1 "$?" "floor 3 -- 1 lost"

# warning-gate: the warning leg picks the section
d=$(fixture w1)
mkdir -p "$d/build/CMakeFiles/4.0.0"
: > "$d/build/CMakeCache.txt"
printf 'set(CMAKE_CXX_COMPILER_ID "GNU")\nset(CMAKE_CXX_COMPILER_VERSION "16.1.0")\n' \
    > "$d/build/CMakeFiles/4.0.0/CMakeCXXCompiler.cmake"
printf '[1/2] Building CXX object a.o\n[2/2] Building CXX object b.o\n' > "$d/build.log"
printf '{"GNU-16/both": {"min_compile_units": 2, "project": {}, "system": {}, "system_reasons": {}}}\n' \
    > "$d/ci/warning-baseline.json"
commit "$d"
expect "14 warning-gate is judged by the warning leg's section" 0 \
    "$(rg "$d" --gates warning-gate --build-dir build --build-log build.log --warning-leg both)" \
    "at or below the GNU-16/both baseline"
expect "15 without the warning leg the compiler key has no section (--require-key)" 1 \
    "$(rg "$d" --gates warning-gate --build-dir build --build-log build.log)" \
    "GNU-16 is not in the baseline"

# --- the consumer's own self-tests, with the build dir exported
d=$(fixture t1)
mkdir -p "$d/ci/scripts"
cat > "$d/ci/scripts/own.selftest.sh" <<'ST'
#!/usr/bin/env bash
[ "${BUILD_DIR:-}" = build ] || { echo "BUILD_DIR not handed over"; exit 1; }
echo "selftest: 1 cases, 1 red-proved"
ST
commit "$d"
expect "16 the consumer's self-tests run, and see BUILD_DIR" 0 \
    "$(rg "$d" --gates selftests --build-dir build)" "own.selftest.sh" "1 passed, 0 failed"
expect "17 without the build dir they do not" 1 "$(rg "$d" --gates selftests)" \
    "BUILD_DIR not handed over"

# --- deps-lock reaches bump-deps with this consumer's root and name
d=$(fixture lk)
printf 'LibreAgent https://github.com/LibreSCRS/LibreAgent not-a-sha\n' > "$d/deps.lock"
commit "$d"
(cd "$T" && REPO_ROOT="$d" python3 "$RG" --repo LibreKDE --gates deps-lock) >"$out" 2>&1
expect "18 deps-lock: a malformed lock row fails" 1 "$?" "deps.lock"
(cd "$T" && REPO_ROOT="$d" python3 "$RG" --repo LibreKDE --gates deps-lock-build) >"$out" 2>&1
expect "19 deps-lock-build: no build dir is 'cannot judge'" 2 "$?" "build-dir"

# --- check-version-lockstep reaches check-version.sh against this root
d=$(fixture ver)
printf '5.0.0\n' > "$d/VERSION"
printf '# Changelog\n\n## [4.2.0]\n\n- old\n' > "$d/CHANGELOG.md"
commit "$d"
expect "20 check-version-lockstep: no CHANGELOG section for VERSION fails" 1 \
    "$(rg "$d" --gates check-version-lockstep)"
printf '# Changelog\n\n## [Unreleased] \xe2\x80\x94 5.0.0\n\n- new\n' > "$d/CHANGELOG.md"
commit "$d"
expect "21 check-version-lockstep: the section for VERSION passes" 0 \
    "$(rg "$d" --gates check-version-lockstep)"

[ "$fails" = 0 ] && echo "run-gates selftest: all cases behave" || echo "run-gates selftest: FAILED"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit "$fails"
