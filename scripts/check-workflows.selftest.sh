#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# check-workflows.selftest.sh -- perturbs every rule of check-workflows.py,
# never just runs it. Each case asserts the exit code AND the message, because
# a gate that fails for the wrong reason is not a gate.
#
# Sections A, B and C are the cases of the three checks this one replaced, kept
# case for case: the wiring check (A, fourteen), the timeout check (B, six) and
# the step-order check (C). They now run the merged gate from outside each
# fixture, with the fixture named by REPO_ROOT -- the gate lives in one
# repository and judges another.
#
# The sections after them are the new behaviour: a step calling
# LibreSCRS/ci/actions/gates is resolved through the consumer's profile (D),
# a gates step is placed and reached like any gate step (E), every reference
# to LibreSCRS/ci pins one full commit (F), the rules combine into one exit
# code (G), and the root comes from the environment, never the script (H).
#
# Fixtures are throw-away git checkouts under ${TMPDIR:-/var/tmp}.
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"
GATE="$here/check-workflows.py"
FIXTURES="$repo/fixtures/check-workflows"
[ -f "$GATE" ] || { echo "FATAL: gate not found at $GATE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is not on PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: python3 cannot import yaml -- cannot judge" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/check-workflows-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/no-profiles" "$T/timeouts" "$T/order"
fails=0
failed=0
cases=0
red=0
out="$T/out"

# say <status> <label> <gate-rc>: <gate-rc> is what the gate was expected to
# return for this case, and a non-zero one is a case that proved the gate red.
say() {
  cases=$((cases + 1))
  if [ "${3:-0}" != 0 ]; then red=$((red + 1)); fi
  if [ "$1" = 0 ]; then printf 'PASS  %s\n' "$2"; else printf 'FAIL  %s\n' "$2"; fails=1; fi
}

# ===================== A. wired (the fourteen wiring cases) ================
mkfixture() {  # mkfixture <dir>
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/ci/scripts" "$d/tools" "$d/.github/workflows"
  printf '#!/bin/sh\nexit 0\n' > "$d/ci/scripts/wired.sh"
  printf '#!/bin/sh\nexit 0\n' > "$d/tools/hop.sh"
  # A self-test and a runner, because every repository here has both and the
  # gate now asks the runner what it would execute. The runner picks its set the
  # way the real one does -- by pathspec, not by a list in its body.
  printf '#!/bin/sh\nexit 0\nprintf "selftest: 1 cases, 1 red-proved\\n"\n' > "$d/ci/scripts/wired.selftest.sh"
  cat > "$d/ci/scripts/run-selftests.sh" <<'RUNNER'
#!/bin/sh
cd "$(dirname "$0")/../.." || exit 2
if [ "${1:-}" = --list ]; then
    git ls-files -- 'ci/*' 'tools/*' 'packaging/*' 'scripts/*' 'Scripts/*' 'e2e/*' | grep '\.selftest\.' | sort
    exit 0
fi
exit 0
RUNNER
  chmod +x "$d/ci/scripts/run-selftests.sh" "$d/ci/scripts/wired.selftest.sh"
  printf 'jobs:\n  lint:\n    steps:\n      - run: ci/scripts/wired.sh\n      - run: ci/scripts/run-selftests.sh\n      - run: ci/scripts/check-gates-wired.sh\n' > "$d/.github/workflows/ci.yml"
  printf 'cmake_minimum_required(VERSION 3.24)\n' > "$d/CMakeLists.txt"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.email=s@e -c user.name=s commit -qm f
}
run() { (cd "$T" && REPO_ROOT="$1" python3 "$GATE" --profiles "$T/no-profiles" wired) >"$T/out" 2>&1; echo $?; }

# 1. wired script + a script the wired one names (one hop) -> green
mkfixture "$T/a"
printf '#!/bin/sh\ntools/hop.sh\n' > "$T/a/ci/scripts/wired.sh"
git -C "$T/a" add -A; git -C "$T/a" -c user.email=s@e -c user.name=s commit -qm h
rc=$(run "$T/a")
[ "$rc" = 0 ] && grep -q 'OK: every shipped gate is wired' "$T/out"; say $? "1 green: wired + one hop" 0

# 2. PERTURBATION: drop the mention from the workflow -> red, and it names the file
mkfixture "$T/b"
printf 'jobs:\n  lint:\n    steps:\n      - run: ci/scripts/run-selftests.sh\n      - run: ci/scripts/check-gates-wired.sh\n' > "$T/b/.github/workflows/ci.yml"
git -C "$T/b" add -A; git -C "$T/b" -c user.email=s@e -c user.name=s commit -qm p
rc=$(run "$T/b")
[ "$rc" = 1 ] && grep -q 'FAIL: ci/scripts/wired.sh is shipped' "$T/out"; say $? "2 red when nothing names the script" 1

# 3. ANTI-CHEAT: the only mention is a YAML comment -> still red
mkfixture "$T/c"
printf 'jobs:\n  lint:\n    steps:\n      # ci/scripts/wired.sh used to run here\n      - run: ci/scripts/run-selftests.sh\n      - run: ci/scripts/check-gates-wired.sh\n' \
  > "$T/c/.github/workflows/ci.yml"
git -C "$T/c" add -A; git -C "$T/c" -c user.email=s@e -c user.name=s commit -qm c
rc=$(run "$T/c")
[ "$rc" = 1 ] && grep -q 'FAIL: ci/scripts/wired.sh is shipped' "$T/out"; say $? "3 a comment does not count as wiring" 1

# 4. allowlist entry without a reason -> red, and it says so
mkfixture "$T/d"
printf 'jobs:\n  lint:\n    steps:\n      - run: ci/scripts/run-selftests.sh\n      - run: ci/scripts/check-gates-wired.sh\n' > "$T/d/.github/workflows/ci.yml"
printf 'ci/scripts/wired.sh\n' > "$T/d/ci/gate-wiring-exceptions.txt"
git -C "$T/d" add -A; git -C "$T/d" -c user.email=s@e -c user.name=s commit -qm d
rc=$(run "$T/d")
[ "$rc" = 1 ] && grep -q "carries no reason" "$T/out"; say $? "4 allowlist without a reason is refused" 1

# 5. allowlist with a reason -> green, and the skip is printed
mkfixture "$T/e"
printf 'jobs:\n  lint:\n    steps:\n      - run: ci/scripts/run-selftests.sh\n      - run: ci/scripts/check-gates-wired.sh\n' > "$T/e/.github/workflows/ci.yml"
printf 'ci/scripts/wired.sh  run by hand at release time, see docs/RELEASE.md\ntools/hop.sh  same\n' \
  > "$T/e/ci/gate-wiring-exceptions.txt"
git -C "$T/e" add -A; git -C "$T/e" -c user.email=s@e -c user.name=s commit -qm e
rc=$(run "$T/e")
[ "$rc" = 0 ] && grep -q 'SKIP: ci/scripts/wired.sh' "$T/out"; say $? "5 allowlist with a reason is honoured" 0

# 6. stale allowlist entry (path no longer tracked) -> red
mkfixture "$T/f"
printf 'jobs:\n  lint:\n    steps:\n      - run: ci/scripts/wired.sh\n      - run: ci/scripts/check-gates-wired.sh\n' > "$T/f/.github/workflows/ci.yml"
printf 'ci/scripts/gone.sh  deleted last cycle\n' > "$T/f/ci/gate-wiring-exceptions.txt"
printf '#!/bin/sh\nexit 0\n' > "$T/f/tools/hop.sh"
printf '#!/bin/sh\ntools/hop.sh\n' > "$T/f/ci/scripts/wired.sh"
git -C "$T/f" add -A; git -C "$T/f" -c user.email=s@e -c user.name=s commit -qm f2
rc=$(run "$T/f")
[ "$rc" = 1 ] && grep -q 'stale entry' "$T/out"; say $? "6 stale allowlist entry is refused" 1

# 7. no candidates at all -> 2 (cannot judge), never 0
mkfixture "$T/g"
git -C "$T/g" rm -q -r --cached tools >/dev/null
git -C "$T/g" rm -q --cached ci/scripts/wired.sh ci/scripts/run-selftests.sh \
    ci/scripts/wired.selftest.sh >/dev/null
rm -rf "$T/g/tools" "$T/g/ci/scripts/wired.sh" "$T/g/ci/scripts/run-selftests.sh" \
    "$T/g/ci/scripts/wired.selftest.sh"
git -C "$T/g" add -A; git -C "$T/g" -c user.email=s@e -c user.name=s commit -qm g
rc=$(run "$T/g")
[ "$rc" = 2 ] && grep -q 'no candidate scripts found' "$T/out"; say $? "7 an empty candidate set is 'cannot judge' (2), not pass" 2

# 8. an exception is a ROOT, not a pardon: what it calls is covered too
mkfixture "$T/h"
printf 'jobs:\n  lint:\n    steps:\n      - run: ci/scripts/run-selftests.sh\n      - run: ci/scripts/check-gates-wired.sh\n' > "$T/h/.github/workflows/ci.yml"
printf '#!/bin/sh\ntools/hop.sh\n' > "$T/h/ci/scripts/wired.sh"
# shellcheck disable=SC2016  # the \$stage is the text of the reason
printf 'ci/scripts/wired.sh  invoked as ci/scripts/$stage.sh by the release job\n' \
  > "$T/h/ci/gate-wiring-exceptions.txt"
git -C "$T/h" add -A; git -C "$T/h" -c user.email=s@e -c user.name=s commit -qm h8
rc=$(run "$T/h")
[ "$rc" = 0 ] && grep -q 'SKIP: ci/scripts/wired.sh' "$T/out" && ! grep -q 'tools/hop.sh is shipped' "$T/out"
say $? "8 an exception seeds reachability for what it calls" 0

# 9. a packaging recipe that nothing names -> red. This case exists because the
# candidate pathspec is data the gate cannot check about itself: one sibling
# copy lost 'packaging/arch/*' from it and went green over a whole directory of
# shipped scripts, which no comparison of the six copies' contents would have
# explained on its own. The fixture makes the pathspec observable.
mkfixture "$T/i"
printf '#!/bin/sh\ntools/hop.sh\n' > "$T/i/ci/scripts/wired.sh"
mkdir -p "$T/i/packaging/arch"
printf '#!/bin/sh\nexit 0\n' > "$T/i/packaging/arch/check-recipe.sh"
git -C "$T/i" add -A; git -C "$T/i" -c user.email=s@e -c user.name=s commit -qm i9
rc=$(run "$T/i")
[ "$rc" = 1 ] && grep -q 'FAIL: packaging/arch/check-recipe.sh is shipped' "$T/out"
say $? "9 a packaging recipe that nothing names is red" 1

# 10. A self-test the repository ships that the runner would NOT execute. This
#     is the shape the `grep -v` hid: reachability by name says nothing about a
#     set chosen by pathspec, so the gate has to ask the runner.
mkfixture "$T/j"
mkdir -p "$T/j/e2e"
printf '#!/bin/sh\nexit 0\nprintf "selftest: 1 cases, 1 red-proved\\n"\n' > "$T/j/e2e/lost.selftest.sh"
sed -i.bak "s|'ci/\*' 'tools/\*' 'packaging/\*' 'scripts/\*' 'Scripts/\*' 'e2e/\*'|'ci/*'|" "$T/j/ci/scripts/run-selftests.sh" \
    && rm -f "$T/j/ci/scripts/run-selftests.sh.bak"
git -C "$T/j" add -A; git -C "$T/j" -c user.email=s@e -c user.name=s commit -qm j10
rc=$(run "$T/j")
[ "$rc" = 1 ] && grep -q 'e2e/lost.selftest.sh' "$T/out" && grep -q 'the runner would not run' "$T/out"
say $? "10 a shipped self-test the runner would not run is red" 1

# 11. The other direction: the runner would run something the repository does not
#     track. A set that is equal in one direction only is not equal.
mkfixture "$T/k"
sed -i.bak 's|exit 0$|printf "ci/scripts/phantom.selftest.sh\\n"; exit 0|' "$T/k/ci/scripts/run-selftests.sh" \
    && rm -f "$T/k/ci/scripts/run-selftests.sh.bak"
git -C "$T/k" add -A; git -C "$T/k" -c user.email=s@e -c user.name=s commit -qm k11
rc=$(run "$T/k")
[ "$rc" = 1 ] && grep -q 'phantom.selftest.sh' "$T/out"
say $? "11 a self-test the runner names and the repository does not ship is red" 1

# 12. No runner at all -> cannot judge. Not green: a repository that ships
#     self-tests and has nothing to run them is the situation this exists for.
mkfixture "$T/l"
git -C "$T/l" rm -q --cached ci/scripts/run-selftests.sh >/dev/null
rm -f "$T/l/ci/scripts/run-selftests.sh"
git -C "$T/l" -c user.email=s@e -c user.name=s commit -qm l12
rc=$(run "$T/l")
[ "$rc" = 2 ] && grep -q 'run-selftests.sh' "$T/out"
say $? "12 no runner is 'cannot judge' (2), not pass" 2

# 13. A runner whose --list prints nothing while the repository ships a
#     self-test: an empty answer is not an empty set.
mkfixture "$T/m"
printf '#!/bin/sh\nexit 0\n' > "$T/m/ci/scripts/run-selftests.sh"
chmod +x "$T/m/ci/scripts/run-selftests.sh"
git -C "$T/m" add -A; git -C "$T/m" -c user.email=s@e -c user.name=s commit -qm m13
rc=$(run "$T/m")
[ "$rc" = 2 ] && grep -qF -e '--list' "$T/out"
say $? "13 a runner that lists nothing is 'cannot judge' (2)" 2

# 14. A tracked script under scripts/ that nothing names. The old pathspec did
#     not look there, so a release helper could ship and run nowhere; measured
#     across this project, widening the scan brought 23 such scripts into view.
mkfixture "$T/n"
mkdir -p "$T/n/scripts"
printf '#!/bin/sh\nexit 0\n' > "$T/n/scripts/helper.sh"
printf '#!/bin/sh\ntools/hop.sh\n' > "$T/n/ci/scripts/wired.sh"
git -C "$T/n" add -A; git -C "$T/n" -c user.email=s@e -c user.name=s commit -qm n14
rc=$(run "$T/n")
[ "$rc" = 1 ] && grep -q 'FAIL: scripts/helper.sh is shipped' "$T/out"
say $? "14 a script under scripts/ that nothing names is red" 1

# ===================== B. timeouts (the six bound cases) ====================
trun() {  # trun <name> <expected-rc> <dir>
    local name=$1 want=$2 dir=$3
    cases=$((cases + 1))
    if [ "$want" != 0 ]; then red=$((red + 1)); fi
    (cd "$T" && REPO_ROOT="$T/a" python3 "$GATE" timeouts "$dir") > "$T/timeouts/out" 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-52s rc=%s  %s\n' "$name" "$got" "$(grep -m1 '^jobs=' "$T/timeouts/out" || true)"
    else
        printf '  FAIL  %-52s rc=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$T/timeouts/out"
        fails=1
    fi
}
# case_1 -- a job with no bound at all must fail.
d=$T/timeouts/case_1; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
Y
trun "case_1 unbounded job" 1 "$d"

# case_2 -- a bound that lives INSIDE a step must not count for the job. This
# is the one a naive grep gets wrong, and this project's own CI file has both
# levels in the same file.
d=$T/timeouts/case_2; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
        timeout-minutes: 5
Y
trun "case_2 step-level bound does not bound the job" 1 "$d"

# case_3 -- a bound indented under `on:` rather than under a job.
d=$T/timeouts/case_3; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on:
  schedule:
    timeout-minutes: 30
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
Y
trun "case_3 bound outside the jobs mapping" 1 "$d"

# case_4 -- a file with no jobs: key contributes no jobs and no failure.
d=$T/timeouts/case_4; mkdir -p "$d"
printf 'name: nothing\non: [push]\n' > "$d/a.yml"
trun "case_4 file with no jobs key" 0 "$d"

# case_5 -- a well-formed file passes, and reports the right census.
d=$T/timeouts/case_5; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - run: true
        timeout-minutes: 5
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - run: true
Y
trun "case_5 two bounded jobs" 0 "$d"
if grep -q '^jobs=2 bounded=2 unbounded=0$' "$T/timeouts/out"; then
    printf '  ok    %-52s\n' "case_5 census is 2/2/0"
else
    printf '  FAIL  %-52s\n' "case_5 census is 2/2/0"; fails=1
fi

# case_6 -- an empty directory is an error, not a pass. A check that reports
# success because it found nothing to check is the vacuous kind.
d=$T/timeouts/case_6; mkdir -p "$d"
trun "case_6 no workflow files is an error, not a pass" 2 "$d"

# ===================== C. order (the step-order cases) =====================
# run <root> <args...> -- judges <root> from outside it; output in $out.
run() {
    local cwd="$1"
    shift
    (cd "$T" && REPO_ROOT="$cwd" python3 "$GATE" order "$@") >"$out" 2>&1
}

judge() {
    local want=$1 name=$2 got=$3
    shift 3
    cases=$((cases + 1))
    if [ "$got" != "$want" ]; then
        printf 'FAIL  %s: wanted exit %s, got %s\n' "$name" "$want" "$got"
        sed -n '1,8p' "$out" | sed 's/^/  | /'
        failed=1
        return
    fi
    local needle
    for needle in "$@"; do
        if ! grep -qF -- "$needle" "$out"; then
            printf 'FAIL  %s: exit %s was right but the output never names %s\n' \
                "$name" "$got" "$needle"
            sed -n '1,10p' "$out" | sed 's/^/  | /'
            failed=1
            return
        fi
    done
    [ "$want" = 0 ] || red=$((red + 1))
    printf 'ok    %s (exit %s)\n' "$name" "$got"
}

# --- a scratch repository the cases can shape ------------------------------
# The fixtures are judged with the subject's cwd here, not in the checkout, so
# the rows that excuse the fixture's own dispatch-only jobs do not have to be
# carried in the repository's real exceptions file (where they would be stale).
mkdir -p "$T/order/scratch/ci" "$T/order/scratch/.github/workflows"
git -C "$T/order/scratch" init -q 2>/dev/null || true
scratch_rows() { printf '%s\n' "$@" >"$T/order/scratch/ci/gate-job-exceptions.txt"; }
FIXTURE_ROWS_MISPLACED=(
    "ll-coverage-misplaced.yml:coverage:13    dispatch-only in the recorded workflow"
    "ll-coverage-misplaced.yml:package:4    never ran in the recorded workflow"
)
FIXTURE_ROWS_FIXED=(
    "ll-coverage-fixed.yml:coverage:10    dispatch-only in the recorded workflow"
    "ll-coverage-fixed.yml:package:4    never ran in the recorded workflow"
)

# --- case 1: the defect, as it was ----------------------------------------
scratch_rows "${FIXTURE_ROWS_MISPLACED[@]}"
run "$T/order/scratch" "$FIXTURES/ll-coverage-misplaced.yml"
judge 1 "the recorded workflow fails, naming all three misplaced steps" $? \
    "Install to the system prefix" "Prove the gate still discriminates" \
    "TSan (agent concurrency)" "before anything provides it"
cp "$out" "$T/order/misplaced.out"

# --- case 2: the same workflow with the steps where they belong ------------
scratch_rows "${FIXTURE_ROWS_FIXED[@]}"
run "$T/order/scratch" "$FIXTURES/ll-coverage-fixed.yml"
judge 0 "the same workflow with the steps moved back passes" $?
cp "$out" "$T/order/fixed.out"

# --- case 3: the perturbation changed something ----------------------------
# A red proof whose output is identical to the green one has proved nothing.
cases=$((cases + 1))
if cmp -s "$T/order/misplaced.out" "$T/order/fixed.out"; then
    printf 'FAIL  the two fixtures produce identical output -- the perturbation is inert\n'
    failed=1
else
    red=$((red + 1))
    printf 'ok    the two fixtures produce different output (the perturbation bites)\n'
fi

# --- case 4: the tracked workflows of this repository must pass ------------
# This is the case that defends against a tightened rule: a `git clone` inside a
# `run:` body providing a later step's directory, and gate steps under a matrix
# condition one leg satisfies, are both here in the real files.
run "$repo"
judge 0 "the tracked workflows of this repository pass" $? "gate step(s)"

# --- case 5: working-directory before and after the checkout ---------------
mk_wf() { mkdir -p "$T/order/scratch/.github/workflows"; cat >"$T/order/scratch/.github/workflows/$1"; }
: >"$T/order/scratch/ci/gate-job-exceptions.txt"

mk_wf t.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: early reader
        working-directory: Sub
        run: echo hi
      - uses: actions/checkout@v4
        with:
          path: Sub
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a working-directory before the checkout that creates it fails" $? "reads 'Sub'"

mk_wf t.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          path: Sub
      - name: later reader
        working-directory: Sub
        run: echo hi
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 0 "the same reader after that checkout passes" $?

mk_wf t.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: make it
        run: mkdir -p Sub
      - name: later reader
        working-directory: Sub
        run: echo hi
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 0 "a directory a run: step creates counts as provided" $?

# --- case 6: a local action before the checkout ----------------------------
mk_wf t.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/thing
      - uses: actions/checkout@v4
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a local action used before the checkout fails" $? "reads '.'"

# --- case 7: the exceptions file, all four ways ---------------------------
mk_wf t.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    if: vars.FOO == 'true'
    steps:
      - uses: actions/checkout@v4
      - name: gate
        run: ./ci/scripts/thing.sh
YML
: >"$T/order/scratch/ci/gate-job-exceptions.txt"
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a gate step in a job that needs a variable fails without a row" $? "no reason is recorded"

scratch_rows "t.yml:j:2    the variable is not set on this repository"
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 0 "the same step passes with a row that carries a reason" $?

scratch_rows "t.yml:j:2"
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a row with an empty reason fails" $? "empty reason"

scratch_rows "t.yml:gone    a reason for a job that is not there"
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a row naming a job that does not exist fails" $? "does not exist"

# --- case 8: a row that excuses something needing no excuse ---------------
mk_wf t.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: gate
        run: ./ci/scripts/thing.sh
YML
scratch_rows "t.yml:j    a reason that has outlived the condition"
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a row for a step that now runs on push fails as stale" $? "outlived"

# --- case 9: the matrix is modelled --------------------------------------
: >"$T/order/scratch/ci/gate-job-exceptions.txt"
mk_wf t.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - os: a
          - os: b
            extra_gates: true
    steps:
      - uses: actions/checkout@v4
      - name: gate
        if: matrix.extra_gates
        run: ./ci/scripts/thing.sh
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 0 "a gate step under a matrix key one leg sets passes" $?

mk_wf t.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - os: a
          - os: b
    steps:
      - uses: actions/checkout@v4
      - name: gate
        if: matrix.extra_gates
        run: ./ci/scripts/thing.sh
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a gate step under a matrix key no leg sets fails" $? "matrix.extra_gates"

# --- case 10: needs: is transitive ---------------------------------------
mk_wf t.yml <<'YML'
on: [push]
jobs:
  dispatch_only:
    runs-on: ubuntu-latest
    if: github.event_name == 'workflow_dispatch'
    steps:
      - uses: actions/checkout@v4
  downstream:
    runs-on: ubuntu-latest
    needs: dispatch_only
    steps:
      - uses: actions/checkout@v4
      - name: gate
        run: ./ci/scripts/thing.sh
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a job needing a dispatch-only job is not on push either" $? "needs: dispatch_only"

# --- case 11: a gate step in a job that checks nothing out ----------------
# The shape a pages workflow has: a deploy job with one step, no checkout, and
# needs: on a build job that did check out. R2 is satisfied -- it does run on
# push -- and the step would read a tree that does not exist.
mk_wf t.yml <<'YML'
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: gate
        run: ./ci/scripts/thing.sh
  deploy:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: gate in the wrong job
        run: ./ci/scripts/thing.sh
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 1 "a gate step in a job that never checks anything out fails" $? \
    "never checks anything out"

mk_wf t.yml <<'YML'
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: gate
        run: ./ci/scripts/thing.sh
      - name: the same gate, in the job that has the tree
        run: ./ci/scripts/thing.sh
  deploy:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/deploy-pages@v4
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/t.yml"
judge 0 "the same gate step in the job that has the tree passes" $?

# --- case 12: the anti-vacuum ---------------------------------------------
# A floor that cannot be breached is not a floor, so it is breached here.
mkdir -p "$T/order/vacuum/ci" "$T/order/vacuum/.github/workflows"
cp "$T/order/scratch/.github/workflows/t.yml" "$T/order/vacuum/.github/workflows/"
git -C "$T/order/vacuum" init -q 2>/dev/null || true
git -C "$T/order/vacuum" add -A >/dev/null 2>&1 || true
printf 'min_workflows 9\nmin_jobs 99\n' >"$T/order/vacuum/ci/workflow-shape.txt"
run "$T/order/vacuum"
judge 2 "a repository with fewer workflows than it declares cannot be judged" $? \
    "ci/workflow-shape.txt declares at least"

printf 'not: [valid\n  yaml: -\n' >"$T/order/scratch/.github/workflows/broken.yml"
run "$T/order/scratch" "$T/order/scratch/.github/workflows/broken.yml"
judge 2 "unloadable YAML is not a clean workflow" $?
rm -f "$T/order/scratch/.github/workflows/broken.yml"

mk_wf empty.yml <<'YML'
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps: []
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/empty.yml"
judge 2 "a job with no steps is not a judgeable job" $?
rm -f "$T/order/scratch/.github/workflows/empty.yml"

# A host whose python3 cannot import yaml must be exit 2, never a pass. The
# import is shimmed away rather than uninstalled.
mkdir -p "$T/order/noyaml"
printf 'raise ImportError("no yaml here")\n' >"$T/order/noyaml/yaml.py"
(cd "$T" && REPO_ROOT="$T/order/scratch" PYTHONPATH="$T/order/noyaml" python3 "$GATE" \
    order "$T/order/scratch/.github/workflows/t.yml") >"$out" 2>&1
judge 2 "a python3 that cannot import yaml cannot judge" $? "PyYAML"

# --- an exception that names a job excuses steps nobody decided about ------
# Measured before this rule: a gate step moved into a dispatch-only job that
# already carried a row, placed AFTER that job's checkout, was accepted by all
# three meta-checks at once. The row had been written for a different step, and
# for a job that then grew one.
mk_wf excused.yml <<'YML'
on: [push]
jobs:
  coverage:
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ci/scripts/coverage-gate.py --check build
YML
scratch_rows "excused.yml:coverage    dispatch-only, and this row names the job"
run "$T/order/scratch" "$T/order/scratch/.github/workflows/excused.yml"
judge 1 "a row that excuses a whole job is not an excuse" $? \
    "excuses the whole of" "excused.yml:coverage:2"

scratch_rows "excused.yml:coverage:2    dispatch-only: the ratchet reads a baseline recorded elsewhere"
run "$T/order/scratch" "$T/order/scratch/.github/workflows/excused.yml"
judge 0 "the same job, with the step named, is excused" $?

# And the step that lands in that job afterwards: the row above still names
# step 2, so the newcomer is unexcused and says so by name.
mk_wf excused.yml <<'YML'
on: [push]
jobs:
  coverage:
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ci/scripts/coverage-gate.py --check build
      - name: Every step can run where it was placed
        run: ci/scripts/workflow-step-order.py
YML
run "$T/order/scratch" "$T/order/scratch/.github/workflows/excused.yml"
judge 1 "a gate step moved into the excused job is not covered by its row" $? \
    "Every step can run where it was placed" "no reason is recorded"
rm -f "$T/order/scratch/.github/workflows/excused.yml"
: >"$T/order/scratch/ci/gate-job-exceptions.txt"

# ===================== D. the shared gates, through the profile ============
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222

# consumer <name> -- a checkout under $T/<name> whose workflow is read from
# stdin, committed with a CMakeLists.txt. Profiles live in $T/<name>.profiles.
consumer() {
    local d="$T/$1"
    rm -rf "$d" "$d.profiles"; mkdir -p "$d/.github/workflows" "$d.profiles"
    cat > "$d/.github/workflows/ci.yml"
    printf 'cmake_minimum_required(VERSION 3.24)\n' > "$d/CMakeLists.txt"
    git -C "$d" init -q
    git -C "$d" add -A
    git -C "$d" -c user.email=s@e -c user.name=s commit -qm c
    printf '%s' "$d"
}
commit() { git -C "$1" add -A && git -C "$1" -c user.email=s@e -c user.name=s commit -qm x; }
# cw <root> <args...>: the merged gate over <root>, profile key Consumer.
cw() {
    (cd "$T" && REPO_ROOT="$1" python3 "$GATE" --repo-name Consumer --profiles "$1.profiles" \
        "${@:2}") >"$out" 2>&1
    echo $?
}
# expect <label> <want-rc> <got-rc> <needle>...
expect() {
    local label=$1 want=$2 got=$3 ok=0 n
    shift 3
    [ "$got" = "$want" ] || ok=1
    for n in "$@"; do grep -qF -- "$n" "$out" || ok=1; done
    [ "$ok" = 0 ] || sed -n '1,12p' "$out" | sed 's/^/  | /'
    say "$ok" "$label (want $want, got $got)" "$want"
}

two_phase_workflow() {
    cat <<YML
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - name: Shared gates
        uses: LibreSCRS/ci/actions/gates@$S1
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - run: cmake -B build && cmake --build build
      - name: Shared gates after the build
        uses: LibreSCRS/ci/actions/gates@${2:-$S1}
        with:
          phase: ${1:-build}
          build-dir: build
          leg: linux
YML
}

d=$(two_phase_workflow | consumer d1)
printf 'check-format-scope\ntest-manifest-gate build\n' > "$d.profiles/Consumer.txt"
expect "D1 every profile phase has a step and every step a phase" 0 "$(cw "$d" wired)" \
    "OK: phase 'build' (test-manifest-gate)" "OK: phase 'static' (check-format-scope)"

printf 'check-format-scope\ntest-manifest-gate build\nwarning-gate asan\n' > "$d.profiles/Consumer.txt"
expect "D2 a profile gate whose phase no step runs is red" 1 "$(cw "$d" wired)" \
    "lists warning-gate in phase 'asan', and no step"

d=$(two_phase_workflow bench | consumer d3)
printf 'check-format-scope\ntest-manifest-gate build\n' > "$d.profiles/Consumer.txt"
expect "D3 a step whose phase the profile does not have is red, both ways" 1 "$(cw "$d" wired)" \
    "phase 'bench', which profiles/Consumer.txt has no gate for" \
    "lists test-manifest-gate in phase 'build'"

d=$(two_phase_workflow | consumer d4)
expect "D4 a gates step with no profile cannot be judged" 2 "$(cw "$d" wired)" \
    "no profile for 'Consumer'"

d=$(two_phase_workflow | consumer d5)
printf '# nothing yet\n\n' > "$d.profiles/Consumer.txt"
expect "D5 an empty profile cannot be judged" 2 "$(cw "$d" wired)" "lists no gate"

# shellcheck disable=SC2016  # a workflow expression, written as the workflow has it
d=$(two_phase_workflow '${{ matrix.phase }}' | consumer d6)
printf 'check-format-scope\ntest-manifest-gate build\n' > "$d.profiles/Consumer.txt"
expect "D6 a phase that is not a literal is red" 1 "$(cw "$d" wired)" "not a literal"

d=$(two_phase_workflow | consumer d7)
printf 'check-format-scope\nnonesuch build\n' > "$d.profiles/Consumer.txt"
expect "D7 a profile naming an unknown gate cannot be judged" 2 "$(cw "$d" wired)" \
    "'nonesuch' is not a gate"

d=$(consumer d8 <<'YML'
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - run: ci/scripts/lint.sh
YML
)
mkdir -p "$d/ci/scripts"; printf '#!/bin/sh\nexit 0\n' > "$d/ci/scripts/lint.sh"; commit "$d"
printf 'check-format-scope\n' > "$d.profiles/Consumer.txt"
expect "D8 a profile no step reaches at all is red" 1 "$(cw "$d" wired)" \
    "lists check-format-scope in phase 'static', and no step"

# D9/D10: a repository whose own runner moved away. Its self-tests are run by
# the profile gate `selftests`; without that gate nothing runs them.
d=$(two_phase_workflow | consumer d9)
mkdir -p "$d/ci/scripts"
printf '#!/bin/sh\nprintf "selftest: 1 cases, 1 red-proved\\n"\n' > "$d/ci/scripts/own.selftest.sh"
commit "$d"
printf 'selftests\ntest-manifest-gate build\n' > "$d.profiles/Consumer.txt"
expect "D9 the profile's selftests gate is the runner" 0 "$(cw "$d" wired)" \
    "(1 self-tests, run by LibreSCRS/ci run-consumer-selftests.sh"
printf 'check-format-scope\ntest-manifest-gate build\n' > "$d.profiles/Consumer.txt"
expect "D10 shipped self-tests and neither runner nor selftests gate cannot be judged" 2 \
    "$(cw "$d" wired)" "'selftests' gate in this repository's profile"

# ===================== E. a gates step is a gate step =======================
d=$(consumer e1 <<YML
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: LibreSCRS/ci/actions/gates@$S1
      - uses: actions/checkout@v4
YML
)
expect "E1 a gates step before the checkout is red" 1 "$(cw "$d" order)" "reads '.'"

d=$(consumer e2 <<YML
on: [push, workflow_dispatch]
jobs:
  lint:
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: LibreSCRS/ci/actions/gates@$S1
YML
)
expect "E2 a gates step in a job that does not run on push is red" 1 "$(cw "$d" order)" \
    "runs LibreSCRS/ci/actions/gates but is not reached on push"

d=$(consumer e3 <<YML
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
        with:
          path: src
      - uses: LibreSCRS/ci/actions/gates@$S1
YML
)
expect "E3 a gates step over a checkout in a subdirectory is red" 1 "$(cw "$d" order)" \
    "reads '.' before anything provides it"

d=$(consumer e3b <<YML
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
        with:
          path: src
      - uses: LibreSCRS/ci/actions/gates@$S1
        with:
          root: src
YML
)
expect "E3b the same step naming that subdirectory as its root passes" 0 "$(cw "$d" order)" \
    "1 gate step(s)"

d=$(two_phase_workflow | consumer e4)
expect "E4 gates steps after the checkout, on push, pass" 0 "$(cw "$d" order)" "2 gate step(s)"

# ===================== F. one pin, a full commit ===========================
d=$(two_phase_workflow | consumer f1)
expect "F1 two uses at one full commit pass" 0 "$(cw "$d" pins)" \
    "2 reference(s) to LibreSCRS/ci, all at $S1"

d=$(two_phase_workflow build "$S2" | consumer f2)
expect "F2 two different commits are red, and both are named" 1 "$(cw "$d" pins)" \
    "2 different commits" "$S1: .github/workflows/ci.yml:" "$S2: .github/workflows/ci.yml:"

d=$(two_phase_workflow build main | consumer f3)
expect "F3 a branch is not a pin" 1 "$(cw "$d" pins)" "at 'main'" "full 40-hex"

d=$(two_phase_workflow build 1111111 | consumer f4)
expect "F4 a short commit is not a pin" 1 "$(cw "$d" pins)" "at '1111111'"

checkout_ci() {
    cat <<YML
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: LibreSCRS/ci/actions/gates@$S1
      - uses: actions/checkout@v4
        with:
          repository: LibreSCRS/ci
          path: .ci
$1
YML
}
d=$(checkout_ci "" | consumer f5)
expect "F5 a checkout of LibreSCRS/ci with no ref floats, and is red" 1 "$(cw "$d" pins)" \
    "(checkout) pins LibreSCRS/ci at '(nothing)'"
d=$(checkout_ci "          ref: $S1" | consumer f6)
expect "F6 a checkout at the same commit counts and passes" 0 "$(cw "$d" pins)" \
    "2 reference(s) to LibreSCRS/ci, all at $S1"
d=$(checkout_ci "          ref: $S2" | consumer f6b)
expect "F6b a checkout at another commit is red" 1 "$(cw "$d" pins)" "2 different commits"

d=$(two_phase_workflow | consumer f7)
mkdir -p "$d/ci"; echo "$S1" > "$d/ci/gates.ref"; commit "$d"
expect "F7 a tracked ci/gates.ref is a second source of truth, and red" 1 "$(cw "$d" pins)" \
    "ci/gates.ref is tracked"

d=$( { two_phase_workflow; printf '      # - uses: LibreSCRS/ci/actions/gates@main\n'; } | consumer f8)
expect "F8 a commented-out reference is not a pin" 0 "$(cw "$d" pins)" "2 reference(s)"

d=$(two_phase_workflow build "$S2" | sed "s|LibreSCRS/ci/actions/gates@$S2|librescrs/ci/actions/gates@$S2|" | consumer f9)
expect "F9 the owner is matched without regard to case" 1 "$(cw "$d" pins)" "2 different commits"

# ===================== G. the rules combine ================================
d=$(two_phase_workflow | consumer g1)
printf 'check-format-scope\ntest-manifest-gate build\n' > "$d.profiles/Consumer.txt"
expect "G1 all four rules green is green" 0 "$(cw "$d")" \
    "check-workflows: wired=0 timeouts=0 order=0 pins=0"

d=$(two_phase_workflow | sed '0,/timeout-minutes: 5/{/timeout-minutes: 5/d}' | consumer g2)
printf 'check-format-scope\ntest-manifest-gate build\n' > "$d.profiles/Consumer.txt"
expect "G2 one rule red is red, and the summary names it" 1 "$(cw "$d")" \
    "job 'lint' has no timeout-minutes" "timeouts=1"

d=$(two_phase_workflow | consumer g3)
expect "G3 one rule that cannot judge is 'cannot judge', not green" 2 "$(cw "$d")" "wired=2"

d=$(two_phase_workflow | sed '0,/timeout-minutes: 5/{/timeout-minutes: 5/d}' | consumer g4)
expect "G4 a finding wins over a rule that could not judge" 1 "$(cw "$d")" "wired=2" "timeouts=1"

# ===================== H. where the root and the profile key come from =====
d=$(two_phase_workflow build "$S2" | consumer h1)
(cd "$T" && GITHUB_WORKSPACE="$d" python3 "$GATE" pins) >"$out" 2>&1
expect "H1 GITHUB_WORKSPACE alone names the checkout" 1 "$?" "2 different commits"
(cd "$d/.github" && python3 "$GATE" pins) >"$out" 2>&1
expect "H2 the checkout around the working directory is judged" 1 "$?" "2 different commits"
(cd "$T" && python3 "$GATE" --root "$d" pins) >"$out" 2>&1
expect "H3 --root names the checkout" 1 "$?" "2 different commits"
mkdir -p "$T/nowhere"
(cd "$T/nowhere" && GIT_CEILING_DIRECTORIES="$T" python3 "$GATE" pins) >"$out" 2>&1
expect "H4 no checkout anywhere cannot be judged" 2 "$?" "no repository to judge"

d=$(two_phase_workflow | consumer h5)
printf 'check-format-scope\ntest-manifest-gate build\n' > "$d.profiles/Consumer.txt"
(cd "$T" && REPO_ROOT="$d" GITHUB_REPOSITORY=LibreSCRS/Consumer python3 "$GATE" \
    --profiles "$d.profiles" wired) >"$out" 2>&1
expect "H5 GITHUB_REPOSITORY picks the profile" 0 "$?" "OK: phase 'build'"
(cd "$T" && REPO_ROOT="$d" GITHUB_REPOSITORY=LibreSCRS/Other python3 "$GATE" \
    --profiles "$d.profiles" wired) >"$out" 2>&1
expect "H6 another repository's name finds no profile, and cannot be judged" 2 "$?" \
    "no profile for 'Other'"

# The noyaml shim of section C covered order; the whole entry point too.
(cd "$T" && REPO_ROOT="$d" PYTHONPATH="$T/order/noyaml" python3 "$GATE") >"$out" 2>&1
expect "H7 a python3 that cannot import yaml cannot judge any rule" 2 "$?" "PyYAML"

[ "$fails" = 0 ] && [ "$failed" = 0 ] && echo "check-workflows selftest: all cases behave" \
    || echo "check-workflows selftest: FAILED"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fails" = 0 ] && [ "$failed" = 0 ]
