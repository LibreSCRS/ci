#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# run-gates.selftest.sh -- the profile runner can fail, refuses what it cannot
# judge, and hands each gate the inputs its phase names.
#
# The failure it exists to rule out is the silent green: a repository whose
# profile went missing, went empty, or has no gate in the phase a step asks
# for would otherwise "pass" by running nothing. Each of those is exit 2 here,
# by name. The happy path is proved against real gates over fixture
# checkouts, so a wrong argument order (a build dir where a leg belongs) is a
# red case rather than a guess.
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY GITHUB_ACTIONS BUILD_DIR

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RG="$here/run-gates.py"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/run-gates-selftest.XXXXXX")" || exit 2
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

# fixture <name>: a consumer checkout with one formatted root, clean.
fixture() {
    local d="$T/$1"
    mkdir -p "$d/ci" "$d/lib" "$T/$1.p"
    printf 'lib\n' > "$d/ci/format-dirs.txt"
    printf 'int a;\n' > "$d/lib/a.cpp"
    git -C "$d" init -q
    git -C "$d" add -A
    git -C "$d" -c user.email=s@e -c user.name=s commit -qm f
    printf '%s' "$d"
}
commit() { git -C "$1" add -A && git -C "$1" -c user.email=s@e -c user.name=s commit -qm x; }
rg() {  # rg <root> <args...>: run for profile key Consumer, from outside <root>
    (cd "$T" && REPO_ROOT="$1" python3 "$RG" --repo Consumer --profiles "$1.p" "${@:2}") \
        >"$out" 2>&1
    echo $?
}

# --- the profiles this repository ships are all well-formed
(cd "$T" && python3 "$RG" --lint) >"$out" 2>&1
expect "1 every shipped profile lints" 0 "$?" "LibreMiddleware.txt" "LibreSCRS.github.io.txt"
mkdir -p "$T/bad-profiles"; printf 'check-workflows static extra\n' > "$T/bad-profiles/X.txt"
(cd "$T" && python3 "$RG" --lint --profiles "$T/bad-profiles") >"$out" 2>&1
expect "2 --lint is red on a malformed line" 1 "$?" "is not <gate> [<phase>]"

# --- refusing to judge
d=$(fixture r1)
expect "3 no profile for the repository" 2 "$(rg "$d")" "no profile for 'Consumer'"
printf '# empty\n\n' > "$d.p/Consumer.txt"
expect "4 an empty profile" 2 "$(rg "$d")" "lists no gate"
printf 'nonesuch\n' > "$d.p/Consumer.txt"
expect "5 an unknown gate" 2 "$(rg "$d")" "'nonesuch' is not a gate"
printf 'check-format-scope\ncheck-format-scope static\n' > "$d.p/Consumer.txt"
expect "6 a gate listed twice in one phase" 2 "$(rg "$d")" "listed twice"
printf 'check-format-scope\n' > "$d.p/Consumer.txt"
expect "7 a phase the profile has no gate in" 2 "$(rg "$d" --phase build)" \
    "has no gate in phase 'build'"
printf 'check-format-scope\ntest-manifest-gate build\n' > "$d.p/Consumer.txt"
expect "8 a phase whose gates lack an input" 2 "$(rg "$d" --phase build --build-dir build)" \
    "need --leg"
mkdir -p "$T/nowhere"
(cd "$T/nowhere" && GIT_CEILING_DIRECTORIES="$T" python3 "$RG" --repo Consumer \
    --profiles "$d.p") >"$out" 2>&1
expect "9 no checkout to judge" 2 "$?" "no repository to judge"

# --- running the static phase
d=$(fixture s1)
printf 'check-format-scope\ncheck-skip-reasons\ntest-manifest-gate build\n' > "$d.p/Consumer.txt"
expect "10 a clean checkout passes every static gate" 0 "$(rg "$d")" \
    "2 gate(s), 2 passed, 0 failed, 0 could not judge"
(cd "$T" && REPO_ROOT="$d" python3 "$RG" --repo Consumer --profiles "$d.p" --list) >"$out" 2>&1
expect "11 --list names the phase's gates and nothing else" 0 "$?" "check-format-scope"
grep -q test-manifest-gate "$out" && { echo "FAIL  11b --list leaked another phase"; fails=1; }
mkdir -p "$d/tools"; printf 'int c;\n' > "$d/tools/stray.cpp"; commit "$d"
expect "12 one gate red is red, and the others still run" 1 "$(rg "$d")" \
    "tools/stray.cpp" "2 gate(s), 1 passed, 1 failed"
d=$(fixture s2); rm "$d/ci/format-dirs.txt"; commit "$d"
printf 'check-format-scope\ncheck-skip-reasons\n' > "$d.p/Consumer.txt"
expect "13 a gate that cannot judge makes the run 'cannot judge'" 2 "$(rg "$d")" \
    "1 passed, 0 failed, 1 could not judge"
printf 'TEST(S, T) { GTEST_SKIP(); }\n' > "$d/lib/t.cpp"; commit "$d"
expect "14 a red gate wins over one that cannot judge" 1 "$(rg "$d")" "1 failed, 1 could not judge"

# --- the profile key and the root from the CI environment
d=$(fixture s3)
printf 'check-format-scope\n' > "$d.p/Consumer.txt"
(cd "$T" && GITHUB_WORKSPACE="$d" GITHUB_REPOSITORY=LibreSCRS/Consumer python3 "$RG" \
    --profiles "$d.p") >"$out" 2>&1
expect "15 GITHUB_WORKSPACE and GITHUB_REPOSITORY pick root and profile" 0 "$?" "Consumer phase static"
(cd "$T" && GITHUB_WORKSPACE="$d" GITHUB_REPOSITORY=someone/Other python3 "$RG" \
    --profiles "$d.p") >"$out" 2>&1
expect "16 another repository's name is not this profile" 2 "$?" "no profile for 'Other'"

# --root names a checkout in a subdirectory of the working directory
d=$(fixture s4)
printf 'check-format-scope\n' > "$d.p/Consumer.txt"
mkdir -p "$d/tools"; printf 'int c;\n' > "$d/tools/stray.cpp"; commit "$d"
(cd "$T" && GITHUB_WORKSPACE="$T/s3" python3 "$RG" --root s4 --repo Consumer --profiles "$d.p") \
    >"$out" 2>&1
expect "16b --root, relative to the working directory, wins over GITHUB_WORKSPACE" 1 "$?" \
    "tools/stray.cpp"

# --- the build phase hands each gate its inputs
d=$(fixture b1)
mkdir -p "$d/build" "$d/bin"
printf '#!/usr/bin/env bash\nprintf "Test project /x\\n  Test #1: A.One\\n  Test #2: B.Two\\n\\nTotal Tests: 2\\n"\n' \
    > "$d/bin/ctest"; chmod +x "$d/bin/ctest"
printf 'A.One\nB.Two\n' > "$d/ci/test-manifest.linux.txt"; commit "$d"
printf 'test-manifest-gate build\n' > "$d.p/Consumer.txt"
(cd "$T" && PATH="$d/bin:$PATH" REPO_ROOT="$d" python3 "$RG" --repo Consumer --profiles "$d.p" \
    --phase build --build-dir build --leg linux) >"$out" 2>&1
expect "17 test-manifest-gate gets the build dir and the leg" 0 "$?" "2 tests, manifest matches"
(cd "$T" && PATH="$d/bin:$PATH" REPO_ROOT="$d" python3 "$RG" --repo Consumer --profiles "$d.p" \
    --phase build --build-dir build --leg macos) >"$out" 2>&1
expect "18 the leg is the manifest's: another leg has none" 2 "$?" "no manifest at ci/test-manifest.macos.txt"

# warning-gate: the warning leg, not the manifest leg, picks the section
d=$(fixture w1)
mkdir -p "$d/build/CMakeFiles/4.0.0"
: > "$d/build/CMakeCache.txt"
printf 'set(CMAKE_CXX_COMPILER_ID "GNU")\nset(CMAKE_CXX_COMPILER_VERSION "16.1.0")\n' \
    > "$d/build/CMakeFiles/4.0.0/CMakeCXXCompiler.cmake"
printf '[1/2] Building CXX object a.o\n[2/2] Building CXX object b.o\n' > "$d/build.log"
printf '{"GNU-16/both": {"min_compile_units": 2, "project": {}, "system": {}, "system_reasons": {}}}\n' \
    > "$d/ci/warning-baseline.json"
commit "$d"
printf 'warning-gate build\n' > "$d.p/Consumer.txt"
expect "19 warning-gate is judged by the warning leg's section" 0 \
    "$(rg "$d" --phase build --build-dir build --build-log build.log --leg linux --warning-leg both)" \
    "at or below the GNU-16/both baseline"
expect "20 without the warning leg the compiler key has no section (--require-key)" 1 \
    "$(rg "$d" --phase build --build-dir build --build-log build.log --leg both)" \
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
printf 'selftests build\n' > "$d.p/Consumer.txt"
expect "21 the consumer's self-tests run, and see BUILD_DIR" 0 \
    "$(rg "$d" --phase build --build-dir build)" "own.selftest.sh" "1 passed, 0 failed"
expect "22 without the build dir they do not" 1 "$(rg "$d" --phase build --build-dir '')" \
    "BUILD_DIR not handed over"

[ "$fails" = 0 ] && echo "run-gates selftest: all cases behave" || echo "run-gates selftest: FAILED"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit "$fails"
