#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-deps.sh over throw-away local repositories: the closure is
# transitive and ordered, one upstream at two commits is red, a malformed lock
# is red, an unfetchable commit cannot be judged, and checkout lands on the
# locked commit.
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-deps.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-deps-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$work"
unset REPO_ROOT GITHUB_WORKSPACE

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; sed 's/^/  | /' "$work/err" 2>/dev/null; fail=1; fi
}
mkrepo() {  # mkrepo NAME [lock-content] -> prints the new commit
    local d="$work/up/$1"
    [ -d "$d" ] || { mkdir -p "$d"; git -C "$d" init -q -b main; }
    if [ $# -ge 2 ]; then printf '%s\n' "$2" >"$d/deps.lock"; git -C "$d" add deps.lock; fi
    printf '%s\n' "$RANDOM$RANDOM" >"$d/f"; git -C "$d" add f
    git -C "$d" commit -q -m "c" && git -C "$d" rev-parse HEAD
}
consumer() {  # consumer <lock-content> -> $work/c
    rm -rf "$work/c"; mkdir -p "$work/c"; printf '%s\n' "$1" >"$work/c/deps.lock"
}
run() { PKG_DEPS_CACHE="$work/cache" "$tool" "$@" >"$work/out" 2>"$work/err"; }

M1="$(mkrepo LM)"; M2="$(mkrepo LM)"
A1="$(mkrepo LA "LM $work/up/LM $M1")"
U="$work/up"

# bottom of the stack: no lock, no upstream
rm -rf "$work/c"; mkdir -p "$work/c"
run closure --root "$work/c"; rc=$?; test ! -s "$work/out"; expect "no deps.lock is no upstream" "0 0" "$rc $?"

# direct: LA locks LM
consumer "# comment
LM $U/LM $M1"
run closure --root "$work/c"; rc=$?
test "$(cat "$work/out")" = "LM $U/LM $M1"; expect "one direct upstream (three columns out)" "0 0" "$rc $?"

# transitive: LC locks only LA; LA's own lock at that commit brings LM, first
consumer "LA $U/LA $A1"
run closure --root "$work/c"; rc=$?
test "$(cut -d' ' -f1 "$work/out" | tr '\n' ' ')" = "LM LA "; order=$?
grep -q "^LM $U/LM $M1$" "$work/out"; lmsha=$?
expect "transitive closure, dependencies first, at the dependency's locked commit" "0 0 0" "$rc $order $lmsha"

# REPO_ROOT is the default root (never the script's own location)
consumer "LM $U/LM $M1"
REPO_ROOT="$work/c" PKG_DEPS_CACHE="$work/cache" "$tool" closure >"$work/out" 2>"$work/err"; rc=$?
grep -q "^LM " "$work/out"; expect "REPO_ROOT names the consumer" "0 0" "$rc $?"

# diamond: LL locks LM@M2 but LA@A1 locks LM@M1
consumer "LM $U/LM $M2
LA $U/LA $A1"
run closure --root "$work/c"; expect "one upstream at two commits is red" 1 $?

# --ref replaces the lock with the branch head -- and the diamond goes away
# when both paths resolve to the same head
run closure --root "$work/c" --ref LM=main; rc=$?
grep -q "^LM $U/LM $M2$" "$work/out"; expect "--ref LM=main takes upstream main for every path" "0 0" "$rc $?"

# malformed rows
consumer "LM $U/LM $M1 main"
run closure --root "$work/c"; expect "a fourth column (the old format) is red" 1 $?
grep -q 'drop column 4' "$work/err"; expect "and the finding says to drop it" 0 $?
consumer "LM $U/LM"
run closure --root "$work/c"; expect "two fields is red" 1 $?
consumer "LM $U/LM ${M1:0:12}"
run closure --root "$work/c"; expect "short commit is red" 1 $?
A3="$(mkrepo LA "LM $U/LM $M1 main")"
consumer "LA $U/LA $A3"
run closure --root "$work/c"; expect "a fourth column in an upstream's own lock is red" 1 $?
A2="$(mkrepo LA "LM $U/LM notasha")"
consumer "LA $U/LA $A2"
run closure --root "$work/c"; expect "malformed lock inside an upstream is red" 1 $?

# cannot judge
consumer "LM $U/LM $(printf 'd%.0s' $(seq 40))"
run closure --root "$work/c"; expect "unfetchable commit cannot be judged" 2 $?
run closure --root "$work/nonexistent"; expect "missing root cannot be judged" 2 $?

# checkout lands on the locked commit, never on a branch
run checkout "$U/LM" "$M1" "$work/co"; rc=$?
test "$(git -C "$work/co" rev-parse HEAD)" = "$M1"; expect "checkout is the locked commit (not main)" "0 0" "$rc $?"
run checkout "$U/LM" "$(printf 'e%.0s' $(seq 40))" "$work/co2"; expect "checkout of an absent commit cannot be judged" 2 $?
run checkout "$U/LM" "${M1:0:12}" "$work/co3"; expect "checkout of a short commit is red" 1 $?

[ "$fail" -eq 0 ] || { echo "pkg-deps.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
