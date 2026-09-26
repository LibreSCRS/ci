#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# run-selftests.selftest.sh -- the consumer runner judges the
# checkout it is pointed at, and holds every self-test there to the same
# contract as this repository's own runner: exit 0 AND a last stdout line
# `selftest: <n> cases, <r> red-proved` with n > 0 and r > 0.
#
# It runs from this repository and judges another, so every case points it at
# a fixture from a directory outside that fixture. A runner that found its
# checkout from its own path would list this repository's self-tests instead,
# and case 1 would name the wrong files.
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
R="$here/run-selftests.sh"
T="$(mktemp -d "/var/tmp/rcs-selftest.XXXXXX")" || exit 2
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
        sed -n '1,12p' "$out" | sed 's/^/  | /'
        fails=1
    fi
}

GOOD='#!/usr/bin/env bash
echo "selftest: 3 cases, 2 red-proved"'
# consumer <name> <path=body>...: a committed checkout holding those files.
consumer() {
    local d="$T/$1" spec path
    shift
    mkdir -p "$d"
    for spec in "$@"; do
        path="${spec%%=*}"
        mkdir -p "$d/$(dirname "$path")"
        printf '%s\n' "${spec#*=}" > "$d/$path"
    done
    git -C "$d" init -q
    git -C "$d" add -A
    git -C "$d" -c user.email=s@e -c user.name=s commit -qm c
    printf '%s' "$d"
}
run() { (cd "$T" && bash "$R" "$@") >"$out" 2>&1; echo $?; }

d=$(consumer c1 "ci/scripts/a.selftest.sh=$GOOD" "tools/b.selftest.py=print('selftest: 1 cases, 1 red-proved')" \
    "docs/c.selftest.sh=exit 1")
expect "1 --list names the consumer's self-tests under the pathspec, not ours" 0 \
    "$(run --root "$d" --list)" "ci/scripts/a.selftest.sh" "tools/b.selftest.py"
grep -q 'docs/c.selftest.sh\|run-gates' "$out" && { echo "FAIL  1b listed outside the pathspec or this repository"; fails=1; }
expect "2 every self-test proves a red case: pass" 0 "$(run --root "$d")" \
    "2 selftests, 4 cases, 3 red-proved"
expect "3 REPO_ROOT names the checkout when --root does not" 0 \
    "$( (cd "$T" && REPO_ROOT="$d" bash "$R") >"$out" 2>&1; echo $?)" "2 selftests"

d=$(consumer c4 "ci/scripts/a.selftest.sh=$GOOD" "e2e/f.selftest.sh=exit 1")
expect "4 a failing self-test is red" 1 "$(run --root "$d")" "FAIL  e2e/f.selftest.sh (exit 1)"
d=$(consumer c5 "packaging/g.selftest.sh=echo done")
expect "5 exit 0 without the trailer is red" 1 "$(run --root "$d")" "not the canonical trailer"
d=$(consumer c6 "Scripts/h.selftest.sh=echo 'selftest: 4 cases, 0 red-proved'")
expect "6 a self-test that never saw its gate fail is red" 1 "$(run --root "$d")" "proved no red case"
d=$(consumer c7 "scripts/i.selftest.sh=echo 'selftest: 0 cases, 0 red-proved'")
expect "7 a self-test that ran no case is red" 1 "$(run --root "$d")" "ran no case"
d=$(consumer c8 "ci/scripts/j.selftest.sh=exit 2")
expect "8 a self-test that cannot judge is 'cannot judge'" 2 "$(run --root "$d")" "CANNOT JUDGE"
d=$(consumer c9 "ci/scripts/k.selftest.rb=puts 1")
expect "9 an extension with no interpreter cannot be run" 2 "$(run --root "$d")" "no interpreter"
d=$(consumer c10 "README=nothing")
expect "10 no self-tests at all is 'cannot judge', not green" 2 "$(run --root "$d")" "no self-tests found"
mkdir -p "$T/plain"
expect "11 a root that is not a checkout" 2 \
    "$( (cd "$T" && GIT_CEILING_DIRECTORIES="$T" bash "$R" --root "$T/plain") >"$out" 2>&1; echo $?)" \
    "is not a git checkout"
# With no --root and no REPO_ROOT the runner judges the checkout it lives in.
# A copy of it outside any checkout has nothing to judge: "cannot", not green.
mkdir -p "$T/loose"; cp "$R" "$T/loose/run-selftests.sh"
expect "12 no root, and the runner itself is not in a checkout" 2 \
    "$( (cd "$T" && GIT_CEILING_DIRECTORIES="$T" bash "$T/loose/run-selftests.sh") >"$out" 2>&1; echo $?)" \
    "is not a git checkout"
expect "13 an unknown argument" 2 "$(run --root "$d" --bogus)" "usage"

# A self-test declared for another platform is not run here, says so, and
# leaves the total; one declared for this platform runs. Its body is a failure,
# so a runner that ignored the declaration would go red (the red proof).
plat="$(uname -s | tr '[:upper:]' '[:lower:]')"
OTHER='#!/usr/bin/env bash
# selftest-platforms: plan9
exit 1'
HERE="#!/usr/bin/env bash
# selftest-platforms: plan9 $plat
echo \"selftest: 3 cases, 2 red-proved\""
d=$(consumer c14 "ci/scripts/o.selftest.sh=$OTHER" "ci/scripts/h.selftest.sh=$HERE")
expect "14 a self-test declared for another platform is skipped, visibly" 0 "$(run --root "$d")" \
    "skip  ci/scripts/o.selftest.sh" "declared for: plan9" "1 selftests, 3 cases, 2 red-proved, 1 not for $plat"
d=$(consumer c15 "ci/scripts/o.selftest.sh=${OTHER/plan9/plan9 $plat}")
expect "15 declared for this platform too: it runs, and its failure counts" 1 "$(run --root "$d")" \
    "FAIL  ci/scripts/o.selftest.sh"

[ "$fails" = 0 ] && echo "run-selftests selftest: all cases behave" \
    || echo "run-selftests selftest: FAILED"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit "$fails"
