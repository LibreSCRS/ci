#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# run-selftests.selftest.sh -- prove the runner picks the set the kind names,
# and that a selection which runs nothing is "cannot judge", never a pass.
#
# Fixture: a git checkout with one self-test (a.selftest.sh) and two container
# self-tests (x.dockertest.sh, y.dockertest.py). Each writes a marker when it
# runs, so a case sees what ran, not only the exit code.
#
# Cases:
#   1  default runs a.selftest.sh and no dockertest           -> 0
#   2  --kind docker runs both dockertests and no selftest    -> 0
#   3  --kind docker --only x.dockertest.sh runs x alone      -> 0
#   4  --kind docker in a checkout with no dockertest         -> 2
#   5  --only a name no dockertest has                        -> 2
#   6  --kind docker --only a.selftest.sh (not a dockertest)  -> 2
#   7  --only with a path, not a basename                     -> 2
#   8  --kind bogus                                           -> 2
#   9  --only with no value                                   -> 2
#  10  --only a dockertest declared for another platform      -> 2 (nothing judged)
#  11  a dockertest that fails                                -> 1
#  12  a dockertest without the trailer (same rule as default) -> 1
set -uo pipefail

RUNNER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/run-selftests.sh"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/run-selftests-st.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
MARK="$WORK/mark"
export MARK

cases=0 red=0 fail=0

# fixture NAME FILE=BODY ... -- a checkout holding exactly these files.
fixture() {
    local root="$WORK/$1" spec; shift
    mkdir -p "$root/scripts"
    for spec in "$@"; do printf '%s\n' "${spec#*=}" > "$root/scripts/${spec%%=*}"; done
    if ! { git -C "$root" init -q && git -C "$root" add -A \
        && git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm x; }; then
        echo "FATAL: cannot build fixture $1" >&2; exit 2
    fi
    echo "$root"
}
# shellcheck disable=SC2016  # $MARK expands when the fixture runs, not here
green_sh() { printf 'touch "$MARK/%s"\necho "selftest: 1 cases, 1 red-proved"' "$1"; }
green_py() { printf 'import os\nopen(os.path.join(os.environ["MARK"], "%s"), "w").close()\nprint("selftest: 1 cases, 1 red-proved")' "$1"; }

# run EXPECTED_RC LABEL ROOT ARGS... ; leaves the markers in $ran
run() {
    local want="$1" label="$2" root="$3"; shift 3
    rm -rf "$MARK"; mkdir -p "$MARK"
    bash "$RUNNER" --root "$root" "$@" >"$WORK/out" 2>&1
    local rc=$?
    local f; ran=""
    for f in "$MARK"/*; do [ -e "$f" ] && ran+="${f##*/} "; done
    cases=$((cases + 1))
    [ "$want" = 0 ] || red=$((red + 1))
    if [ "$rc" = "$want" ]; then
        echo "case $label: OK   (rc $rc; ran: ${ran:-nothing})"
        return 0
    fi
    echo "case $label: FAIL expected rc $want, got $rc"; sed 's/^/  | /' "$WORK/out"
    fail=$((fail + 1))
    return 1
}
# says LABEL TEXT -- the runner's output must name the reason, so a usage
# error from a flag the runner does not know never passes for the refusal.
says() {
    grep -qF -- "$2" "$WORK/out" && return 0
    echo "case $1: FAIL output does not say '$2'"; sed 's/^/  | /' "$WORK/out"; fail=$((fail + 1))
}
# ran_is LABEL WANT -- the markers, sorted, must be exactly WANT.
ran_is() {
    [ "$ran" = "$2" ] && return 0
    echo "case $1: FAIL ran '$ran', want '$2'"; fail=$((fail + 1))
}

full="$(fixture full \
    "a.selftest.sh=$(green_sh a)" \
    "x.dockertest.sh=$(green_sh x)" \
    "y.dockertest.py=$(green_py y)")"
plain="$(fixture plain "a.selftest.sh=$(green_sh a)")"
other="$(fixture other \
    "a.selftest.sh=$(green_sh a)" \
    "z.dockertest.sh=# selftest-platforms: nosuchplatform
$(green_sh z)")"
failing="$(fixture failing "x.dockertest.sh=$(green_sh x)
exit 1")"
notrailer="$(fixture notrailer "x.dockertest.sh=touch \"\$MARK/x\"")"

run 0 1 "$full" && ran_is 1 "a "
run 0 2 "$full" --kind docker && ran_is 2 "x y "
run 0 3 "$full" --kind docker --only x.dockertest.sh && ran_is 3 "x "
run 2 4 "$plain" --kind docker && ran_is 4 "" && says 4 "no dockertests found"
run 2 5 "$full" --kind docker --only nosuch.dockertest.sh && ran_is 5 "" \
    && says 5 "no dockertest is named nosuch.dockertest.sh"
run 2 6 "$full" --kind docker --only a.selftest.sh && ran_is 6 "" \
    && says 6 "no dockertest is named a.selftest.sh (scripts/a.selftest.sh is a selftest)"
run 2 7 "$full" --kind docker --only scripts/x.dockertest.sh && ran_is 7 "" && says 7 "--only takes a file name"
run 2 8 "$full" --kind bogus && ran_is 8 "" && says 8 "--kind 'bogus'"
run 2 9 "$full" --kind docker --only && ran_is 9 "" && says 9 "--only needs a file name"
run 2 10 "$other" --kind docker --only z.dockertest.sh && ran_is 10 "" && says 10 "nothing was judged"
run 1 11 "$failing" --kind docker && ran_is 11 "x " && says 11 "FAIL  scripts/x.dockertest.sh (exit 1)"
run 1 12 "$notrailer" --kind docker && ran_is 12 "x " && says 12 "not the canonical trailer"

echo "selftest: $cases cases, $red red-proved"
[ "$fail" = 0 ]
