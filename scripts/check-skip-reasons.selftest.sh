#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# check-skip-reasons.selftest.sh — prove the skip-reason check can fail, and
# prove it does not read a broken scanner as a clean repository.
#
# Cases:
#   1  bare GTEST_SKIP();                      -> 1
#   2  GTEST_SKIP() << "";                     -> 1
#   3  GTEST_SKIP() << "   ";                  -> 1
#   4  GTEST_SKIP() << "no card";              -> 0
#   5  GTEST_SKIP() << env.skipReason;         -> 0  (a run-time reason is a reason)
#   6  the reason on the next line             -> 0  (the argument list spans lines)
#   7  a doc comment mentioning GTEST_SKIP()   -> 0  (comments are not code)
#   8  an untracked file with a bare skip      -> 0  (only git ls-files counts)
#   9  QSKIP("")                               -> 1
#  10  a repository with no tracked sources    -> 2  (nothing scanned is not clean)
#  11  GITHUB_WORKSPACE names a bare skip, cwd elsewhere -> 1 (the CI default)
#  12  no REPO_ROOT, cwd inside that tree      -> 1  (the checkout around cwd)
#  13  no REPO_ROOT, cwd outside every checkout -> 2 (nothing to judge)
#
# The gate is run from outside the fixture, never from a copy placed inside it:
# it lives in one repository and judges another.
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE

CHECK="$(cd "$(dirname "$0")" && pwd)/check-skip-reasons.sh"
WORK="$(mktemp -d /var/tmp/skipreasons-selftest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
cases=0
red=0

make_repo() {
    local name="$1" body="$2"
    local root="$WORK/$name"
    mkdir -p "$root/test"
    printf '%s\n' "$body" > "$root/test/a_test.cpp"
    git -C "$root" init -q
    git -C "$root" config user.email t@t
    git -C "$root" config user.name t
    git -C "$root" add -A
    git -C "$root" -c commit.gpgsign=false commit -qm x
    echo "$root"
}

check() {
    local label="$1" expected="$2" actual="$3"
    cases=$((cases + 1))
    # red-proved: the case in which the gate returned non-zero on a perturbed input.
    if [ "$expected" != 0 ]; then red=$((red + 1)); fi
    if [ "$expected" = "$actual" ]; then
        echo "case $label: OK   — exit $actual"; pass=$((pass + 1))
    else
        echo "case $label: FAIL — expected exit $expected, got $actual"; fail=$((fail + 1))
    fi
}

run() { (cd "$WORK" && REPO_ROOT="$1" bash "$CHECK" 2>&1); }

r="$(make_repo c1 'TEST(S, T) { GTEST_SKIP(); }')"
out="$(run "$r")"; rc=$?; check 1 1 $rc
case "$out" in *"test/a_test.cpp:1"*) ;; *) echo "  case 1: FAIL — did not name file:line"; fail=$((fail + 1)) ;; esac

r="$(make_repo c2 'TEST(S, T) { GTEST_SKIP() << ""; }')"
out="$(run "$r")"; rc=$?; check 2 1 $rc

r="$(make_repo c3 'TEST(S, T) { GTEST_SKIP() << "   "; }')"
out="$(run "$r")"; rc=$?; check 3 1 $rc

r="$(make_repo c4 'TEST(S, T) { GTEST_SKIP() << "no card present"; }')"
out="$(run "$r")"; rc=$?; check 4 0 $rc

r="$(make_repo c5 'TEST(S, T) { GTEST_SKIP() << env.skipReason; }')"
out="$(run "$r")"; rc=$?; check 5 0 $rc

r="$(make_repo c6 "$(printf 'TEST(S, T)\n{\n    GTEST_SKIP()\n        << "reader is absent";\n}\n')")"
out="$(run "$r")"; rc=$?; check 6 0 $rc

r="$(make_repo c7 "$(printf '/// Callers GTEST_SKIP() on nullopt.\n// see GTEST_SKIP() above\nTEST(S, T) { EXPECT_TRUE(true); }\n')")"
out="$(run "$r")"; rc=$?; check 7 0 $rc

r="$(make_repo c8 'TEST(S, T) { EXPECT_TRUE(true); }')"
printf 'TEST(U, V) { GTEST_SKIP(); }\n' > "$r/test/untracked_test.cpp"
out="$(run "$r")"; rc=$?; check 8 0 $rc

r="$(make_repo c9 'void t() { QSKIP(""); }')"
out="$(run "$r")"; rc=$?; check 9 1 $rc

# case 10: a repository with no tracked C/C++ source at all. Nothing scanned
# must read as "cannot judge", not as "clean": a filter that matches nothing is
# the shape that makes a gate vacuous.
r="$WORK/c10"; mkdir -p "$r"
echo readme > "$r/README.md"
git -C "$r" init -q; git -C "$r" config user.email t@t; git -C "$r" config user.name t
git -C "$r" add README.md; git -C "$r" -c commit.gpgsign=false commit -qm x
out="$(run "$r")"; rc=$?; check 10 2 $rc

# cases 11-13: where the root comes from
r="$(make_repo c11 'TEST(S, T) { GTEST_SKIP(); }')"
out="$(cd "$WORK" && GITHUB_WORKSPACE="$r" bash "$CHECK" 2>&1)"; rc=$?; check 11 1 $rc
out="$(cd "$r/test" && bash "$CHECK" 2>&1)"; rc=$?; check 12 1 $rc
mkdir -p "$WORK/nowhere"
out="$(cd "$WORK/nowhere" && GIT_CEILING_DIRECTORIES="$WORK" bash "$CHECK" 2>&1)"; rc=$?; check 13 2 $rc
case "$out" in *"no repository to judge"*) ;; *) echo "  case 13: FAIL — wrong message: $out"; fail=$((fail + 1)) ;; esac

echo "selftest: $pass passed, $fail failed"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fail" = 0 ]
