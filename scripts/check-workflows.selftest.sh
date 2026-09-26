#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# check-workflows.selftest.sh -- perturbs both rules of check-workflows.py.
# Each case asserts the exit code AND the message: a gate that fails for the
# wrong reason is not a gate. Fixtures are throw-away checkouts under /var/tmp,
# judged from outside through REPO_ROOT -- the gate lives in one repository
# and judges another.
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GATE="$here/check-workflows.py"
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: python3 cannot import yaml -- cannot judge" >&2; exit 2; }
T="$(mktemp -d "/var/tmp/check-workflows-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
out="$T/out"
cases=0 red=0 fails=0
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222

# expect <label> <want-rc> <got-rc> <needle>...
expect() {
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
        sed -n '1,12p' "$out" | sed 's/^/  | /'
        fails=1
    fi
}
# consumer <name>: a checkout under $T/<name> whose ci.yml is read from stdin.
consumer() {
    local d="$T/$1"
    rm -rf "$d"; mkdir -p "$d/.github/workflows"
    cat > "$d/.github/workflows/ci.yml"
    git -C "$d" init -q
    git -C "$d" add -A
    git -C "$d" -c user.email=s@e -c user.name=s commit -qm c
    printf '%s' "$d"
}
commit() { git -C "$1" add -A && git -C "$1" -c user.email=s@e -c user.name=s commit -qm x; }
cw() { (cd "$T" && REPO_ROOT="$1" python3 "$GATE" "${@:2}") >"$out" 2>&1; echo $?; }
# tdir <name> <yaml-on-stdin>: a directory holding one workflow, for `timeouts DIR`.
tdir() { mkdir -p "$T/t/$1"; cat > "$T/t/$1/a.yml"; printf '%s' "$T/t/$1"; }
tw() { (cd "$T" && python3 "$GATE" --root "$T" timeouts "$1") >"$out" 2>&1; echo $?; }
git -C "$T" init -q

# ===================== timeouts ===========================================
d=$(tdir t1 <<'Y'
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
Y
)
expect "T1 an unbounded job is red" 1 "$(tw "$d")" "job 'build' has no timeout-minutes"

# The one a naive grep gets wrong: a bound INSIDE a step does not bound the job.
d=$(tdir t2 <<'Y'
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
        timeout-minutes: 5
Y
)
expect "T2 a step-level bound does not bound the job" 1 "$(tw "$d")" "unbounded=1"

d=$(tdir t3 <<'Y'
on:
  schedule:
    timeout-minutes: 30
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
Y
)
expect "T3 a bound outside the jobs mapping does not count" 1 "$(tw "$d")" "unbounded=1"

d=$(printf 'name: nothing\non: [push]\n' | tdir t4)
expect "T4 a file with no jobs key contributes nothing" 0 "$(tw "$d")" "jobs=0"

d=$(tdir t5 <<'Y'
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
)
expect "T5 two bounded jobs pass, census 2/2/0" 0 "$(tw "$d")" "jobs=2 bounded=2 unbounded=0"

mkdir -p "$T/t/t6"
expect "T6 no workflow files is 'cannot judge', not a pass" 2 "$(tw "$T/t/t6")" "no workflow files"

# ===================== pins ===============================================
two_jobs() {  # two_jobs [<ref of the second use>]
    cat <<YML
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: LibreSCRS/ci/actions/gates@$S1
        with:
          gates: check-workflows
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: LibreSCRS/ci/actions/gates@${1:-$S1}
        with:
          gates: test-floor
          build-dir: build
YML
}
d=$(two_jobs | consumer p1)
expect "P1 two uses at one full commit pass" 0 "$(cw "$d" pins)" \
    "2 reference(s) to LibreSCRS/ci, all at $S1"
d=$(two_jobs "$S2" | consumer p2)
expect "P2 two different commits are red, and both are named" 1 "$(cw "$d" pins)" \
    "2 different commits" "$S1: .github/workflows/ci.yml:" "$S2: .github/workflows/ci.yml:"
d=$(two_jobs main | consumer p3)
expect "P3 a branch is not a pin" 1 "$(cw "$d" pins)" "at 'main'" "full 40-hex"
d=$(two_jobs 1111111 | consumer p4)
expect "P4 a short commit is not a pin" 1 "$(cw "$d" pins)" "at '1111111'"

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
d=$(checkout_ci "" | consumer p5)
expect "P5 a checkout of LibreSCRS/ci with no ref floats, and is red" 1 "$(cw "$d" pins)" \
    "(checkout) pins LibreSCRS/ci at '(nothing)'"
d=$(checkout_ci "          ref: $S1" | consumer p6)
expect "P6 a checkout at the same commit counts and passes" 0 "$(cw "$d" pins)" \
    "2 reference(s) to LibreSCRS/ci, all at $S1"
d=$(checkout_ci "          ref: $S2" | consumer p7)
expect "P7 a checkout at another commit is red" 1 "$(cw "$d" pins)" "2 different commits"

d=$(two_jobs | consumer p8)
mkdir -p "$d/ci"; echo "$S1" > "$d/ci/gates.ref"; commit "$d"
expect "P8 a tracked ci/gates.ref is a second source of truth, and red" 1 "$(cw "$d" pins)" \
    "ci/gates.ref is tracked"
d=$( { two_jobs; printf '      # - uses: LibreSCRS/ci/actions/gates@main\n'; } | consumer p9)
expect "P9 a commented-out reference is not a pin" 0 "$(cw "$d" pins)" "2 reference(s)"
d=$(two_jobs "$S2" | sed "s|LibreSCRS/ci/actions/gates@$S2|librescrs/ci/actions/gates@$S2|" | consumer p10)
expect "P10 the owner is matched without regard to case" 1 "$(cw "$d" pins)" "2 different commits"
d=$(two_jobs | consumer p11)
mkdir -p "$d/.github/actions/local"
printf 'runs:\n  using: composite\n  steps:\n    - uses: LibreSCRS/ci/actions/pkg-build@%s\n' "$S2" \
    > "$d/.github/actions/local/action.yml"; commit "$d"
expect "P11 a repository-local action's reference counts too" 1 "$(cw "$d" pins)" \
    "$S2: .github/actions/local/action.yml:4"

# ===================== both rules, one exit code ==========================
d=$(two_jobs | consumer b1)
expect "B1 both rules green is green" 0 "$(cw "$d")" "check-workflows: timeouts=0 pins=0"
d=$(two_jobs | awk '!done && /timeout-minutes: 5/ { done = 1; next } { print }' | consumer b2)
expect "B2 one rule red is red, and the summary names it" 1 "$(cw "$d")" \
    "job 'lint' has no timeout-minutes" "timeouts=1 pins=0"
d=$(two_jobs "$S2" | awk '!done && /timeout-minutes: 5/ { done = 1; next } { print }' | consumer b3)
expect "B3 both rules red" 1 "$(cw "$d")" "timeouts=1 pins=1"
d=$(two_jobs | consumer b4); git -C "$d" rm -qr .github/workflows; commit "$d"
expect "B4 no workflow file: timeouts cannot judge, so the whole is not green" 2 \
    "$(cw "$d")" "timeouts=2"

# ===================== where the root comes from ==========================
d=$(two_jobs "$S2" | consumer h1)
(cd "$T" && GITHUB_WORKSPACE="$d" python3 "$GATE" pins) >"$out" 2>&1
expect "H1 GITHUB_WORKSPACE alone names the checkout" 1 "$?" "2 different commits"
(cd "$d/.github" && python3 "$GATE" pins) >"$out" 2>&1
expect "H2 the checkout around the working directory is judged" 1 "$?" "2 different commits"
(cd "$T" && python3 "$GATE" --root "$d" pins) >"$out" 2>&1
expect "H3 --root names the checkout" 1 "$?" "2 different commits"
mkdir -p "$T/nowhere/deeper"
(cd "$T/nowhere/deeper" && GIT_CEILING_DIRECTORIES="$T/nowhere" python3 "$GATE" pins) >"$out" 2>&1
expect "H4 no checkout anywhere cannot be judged" 2 "$?" "no repository to judge"
d5=$(printf 'jobs: [unclosed\n' | consumer h5)
expect "H5 a workflow that is not YAML cannot be judged" 2 "$(cw "$d5" pins)" "not loadable YAML"
mkdir -p "$T/noyaml"; printf 'raise ImportError("no yaml here")\n' > "$T/noyaml/yaml.py"
(cd "$T" && REPO_ROOT="$d" PYTHONPATH="$T/noyaml" python3 "$GATE") >"$out" 2>&1
expect "H5b a python3 that cannot import yaml cannot judge" 2 "$?" "PyYAML"
(cd "$T" && REPO_ROOT="$d" python3 "$GATE" wired) >"$out" 2>&1
expect "H6 a rule that no longer exists is a usage error" 2 "$?" "usage"

[ "$fails" = 0 ] && echo "check-workflows selftest: all cases behave" || echo "check-workflows selftest: FAILED"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit "$fails"
