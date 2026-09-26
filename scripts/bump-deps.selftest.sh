#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# bump-deps.selftest.sh -- drive bump-deps over fake upstreams (bare repos
# under a temporary directory, served through file:// with partial-clone
# filters allowed, the way GitHub serves them) and a fake side-by-side
# workspace cloned from them.
#
# Each red case perturbs ONE thing against a state the same run has just shown
# green, so a pass means the check saw that perturbation, not something else.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BD="$here/bump-deps"
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY

T="$(mktemp -d "/var/tmp/bd-selftest-XXXXXX")" || { echo "cannot create temp dir" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
export BUMP_DEPS_URL_BASE="file://$T/remotes"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --global user.name "Selftest"
git config --global user.email "selftest@example.invalid"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global tag.gpgsign false
git config --global advice.detachedHead false

CONTRACT=LibreMacAgentClient/Tests/LibreMacAgentClientTests/Contract
REPOS=(LibreMiddleware LibreAgent LibreLinux LibreDarwin LibreCelik LibreKDE LibreMac)
CONSUMERS=(LibreAgent LibreLinux LibreDarwin LibreCelik LibreKDE LibreMac)
WS="$T/ws"

n=0 r=0 fail=0
# expect RC DESC [PATTERN] -- cmd...: passes when the command exits RC and,
# for a red case, its output names the finding PATTERN (grep -E) -- so a case
# cannot pass by going red for some other reason.
expect() {
    local want=$1 desc=$2 pat="" got; shift 2
    if [ "$1" != -- ]; then pat=$1; shift; fi
    shift
    "$@" </dev/null >"$T/out" 2>&1; got=$?
    n=$((n + 1))
    if [ "$got" = "$want" ] && { [ -z "$pat" ] || grep -Eq -- "$pat" "$T/out"; }; then
        [ "$want" = 0 ] || r=$((r + 1))
        echo "ok   $desc (rc=$got)"
    else
        fail=1; echo "FAIL $desc: want rc=$want${pat:+ and /$pat/}, got rc=$got"; sed 's/^/     | /' "$T/out"
    fi
}
# assert DESC -- cmd...: a structural fact about what the tool did.
assert() {
    local desc=$1; shift 2
    n=$((n + 1))
    if "$@" >/dev/null 2>&1; then echo "ok   $desc"
    else fail=1; echo "FAIL $desc"; sed 's/^/     | /' "$T/out"; fi
}
out_has() { grep -q -- "$1" "$T/out"; }
lock_sha() { awk -v d="$2" '$1 == d { print $3 }' "$WS/$1/deps.lock"; }
ahead() { git -C "$WS/$1" rev-list --count origin/main..HEAD; }
all_ahead() { local c; for c in "${CONSUMERS[@]}"; do [ "$(ahead "$c")" = "$1" ] || return 1; done; }
push_all() { local c; for c in "${CONSUMERS[@]}"; do git -C "$WS/$c" push -q origin HEAD:main || return 1; done; }
# perturb CONSUMER SED-EXPR / restore CONSUMER
perturb() { sed -i.bak -e "$2" "$WS/$1/deps.lock" && rm -f "$WS/$1/deps.lock.bak"; }
restore() { git -C "$WS/$1" checkout -q -- deps.lock "$CONTRACT" 2>/dev/null || git -C "$WS/$1" checkout -q -- deps.lock; }
setsha() { perturb "$1" "s/^\($2[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}\)[0-9a-f]\{40\}/\1$3/"; }
# upstream_commit REPO PATH TEXT: someone else pushes to upstream main
upstream_commit() {
    local s="$T/seed/$1"
    git -C "$s" pull -q --ff-only origin main
    mkdir -p "$(dirname -- "$s/$2")"; printf '%s\n' "$3" >>"$s/$2"
    git -C "$s" add -- "$2" && git -C "$s" commit -q -m "change $2" && git -C "$s" push -q origin HEAD:main
}
line_of() { grep -n -- "^$1: committed" "$T/out" | cut -d: -f1; }
in_topo_order() {
    local prev=0 c l
    for c in "${CONSUMERS[@]}"; do
        l="$(line_of "$c")"; [ -n "$l" ] && [ "$l" -gt "$prev" ] || return 1; prev=$l
    done
}

# ------------------------------------------------------------------ fixtures
for R in "${REPOS[@]}"; do
    git init -q --bare "$T/remotes/$R"
    git -C "$T/remotes/$R" config uploadpack.allowFilter true
    git -C "$T/remotes/$R" config uploadpack.allowAnySHA1InWant true
    s="$T/seed/$R"; git init -q "$s"
    case $R in
        LibreMiddleware) mkdir -p "$s/src"; echo lm >"$s/src/lm.c" ;;
        LibreAgent)
            mkdir -p "$s/wire" "$s/include/LibreSCRS/Agent/operations" "$s/src"
            echo '{"schema":1,"vocabularies":{}}' >"$s/wire/wire-vocabulary.json"
            printf '%s\n' 'inline constexpr auto kLongestDeadline{300000};' \
                "inline constexpr auto kMaxSequentialPromptBudget = a + b; // budget-ms: 300'000" \
                >"$s/include/LibreSCRS/Agent/operations/PromptPolicy.h"
            echo la >"$s/src/la.c" ;;
        LibreMac)
            mkdir -p "$s/$CONTRACT"
            echo '{"schema":1,"old":true}' >"$s/$CONTRACT/wire-vocabulary.json"
            echo 'max-sequential-ms 1' >"$s/$CONTRACT/prompt-policy.txt" ;;
        *) echo "$R" >"$s/README" ;;
    esac
    git -C "$s" add -A && git -C "$s" commit -q -m "initial $R"
    git -C "$s" remote add origin "$T/remotes/$R" && git -C "$s" push -q origin HEAD:main
    git clone -q "file://$T/remotes/$R" "$WS/$R"
done

# ------------------------------------------- to-head: first lock, topological
expect 0 "to-head writes the first deps.lock everywhere" -- "$BD" to-head --workspace "$WS"
assert "to-head made exactly one commit in each consumer" -- all_ahead 1
assert "to-head committed in topological order LM>LA>{LL,LD}>{LC,LK}>LMAC" -- in_topo_order
assert "LibreLinux locks the LibreAgent commit to-head just made" -- \
    test "$(lock_sha LibreLinux LibreAgent)" = "$(git -C "$WS/LibreAgent" rev-parse HEAD)"
assert "LibreMac contract regenerated from LibreAgent in the same commit" -- \
    bash -c "cmp -s '$WS/LibreMac/$CONTRACT/wire-vocabulary.json' '$T/seed/LibreAgent/wire/wire-vocabulary.json' \
        && grep -qx 'max-sequential-ms 300000' '$WS/LibreMac/$CONTRACT/prompt-policy.txt' \
        && git -C '$WS/LibreMac' show --stat HEAD | grep -q prompt-policy.txt"
assert "LibreMac locks the LibreDarwin commit to-head just made, in one commit with LibreAgent" -- \
    bash -c "test '$(lock_sha LibreMac LibreDarwin)' = '$(git -C "$WS/LibreDarwin" rev-parse HEAD)' \
        && git -C '$WS/LibreMac' log -1 --format=%s | grep -q '^build: track LibreAgent [0-9a-f]\{12\}, LibreDarwin [0-9a-f]\{12\}$'"
expect 1 "check: a lock naming an unpushed bump is not reachable upstream" 'RED: LibreLinux: LibreAgent [0-9a-f]+ is not reachable' -- "$BD" check --workspace "$WS"
assert "push wave lands" -- push_all
expect 0 "check: green after the push wave" -- "$BD" check --workspace "$WS"
expect 0 "to-head again with nothing new upstream" -- "$BD" to-head --workspace "$WS"
assert "second to-head made no commit" -- all_ahead 0

# ---------------------------------------- upstream moves: one commit each
upstream_commit LibreMiddleware src/lm.c "lm v2"
expect 0 "status runs" -- "$BD" status --workspace "$WS"
assert "status: LibreAgent is 1 behind LibreMiddleware, the gap touches src" -- \
    grep -Eq '^LibreAgent +LibreMiddleware +[0-9a-f]{12} +[0-9a-f]{12} +1 +deps.lock +src$' "$T/out"
expect 0 "to-head after LibreMiddleware moved" -- "$BD" to-head --workspace "$WS"
assert "exactly one commit in each consumer again" -- all_ahead 1
assert "topological order again" -- in_topo_order
assert "LibreLinux's one commit tracks both deps" -- \
    bash -c "git -C '$WS/LibreLinux' log -1 --format=%s | grep -q '^build: track LibreMiddleware [0-9a-f]\{12\}, LibreAgent [0-9a-f]\{12\}$'"
assert "push wave lands" -- push_all
expect 0 "check: green after the second wave" -- "$BD" check --workspace "$WS"

# ------------------------------------------------- the graph's root, unknowns
expect 0 "LibreMiddleware, the graph's root, depends on nothing" "" -- "$BD" check --root "$WS/LibreMiddleware"
assert "and says so" -- grep -q 'ok: LibreMiddleware depends on no LibreSCRS repository' "$T/out"
printf 'LibreAgent %s/LibreAgent %s\n' "$BUMP_DEPS_URL_BASE" "$(git -C "$WS/LibreAgent" rev-parse HEAD)" >"$WS/LibreMiddleware/deps.lock"
expect 1 "a deps.lock in the graph's root is a finding" 'RED: LibreMiddleware is the root of the dependency graph' -- \
    "$BD" check --root "$WS/LibreMiddleware"
rm -f "$WS/LibreMiddleware/deps.lock"
mkdir -p "$T/LibreFoo"
expect 2 "a repository the graph does not know cannot be judged" 'cannot tell which repository' -- \
    "$BD" check --root "$T/LibreFoo"
expect 2 "--consumer naming an unknown repository cannot be judged" "'LibreFoo' is not a LibreSCRS repository" -- \
    "$BD" check --root "$WS/LibreCelik" --consumer LibreFoo

# ------------------------------------------------------------ wrong format
expect 0 "root mode, no network: green control" -- "$BD" check --root "$WS/LibreCelik" --no-remote
# desc | finding the output must name | sed perturbation of the lock
while IFS='|' read -r desc pat expr; do
    perturb LibreCelik "$expr"
    expect 1 "format: $desc" "$pat" -- "$BD" check --root "$WS/LibreCelik" --no-remote
    restore LibreCelik
done <<'CASES'
legacy fourth column|a fourth column \('main'\).*drop column 4|/^LibreAgent/s/$/  main/
two fields|want 3 fields|/^LibreAgent/s/[[:space:]]\{1,\}[0-9a-f]\{40\}$//
five fields|want 3 fields|/^LibreAgent/s/$/ main extra/
short commit|is not 40 lowercase hex|/^LibreAgent/s/\([0-9a-f]\{12\}\)[0-9a-f]\{28\}/\1/
url not the upstream|url '.*LibreAgent.git', want|s#/LibreAgent #/LibreAgent.git #
second row|second row for LibreAgent|/^LibreAgent/p
row missing|no row for LibreAgent|/^LibreAgent/d
CASES

setsha LibreCelik LibreAgent "$(lock_sha LibreCelik LibreAgent | tr a-f A-F)"
expect 1 "format: uppercase commit" 'is not 40 lowercase hex' -- "$BD" check --root "$WS/LibreCelik" --no-remote
restore LibreCelik

# ------------------------------------------------------------ unknown dep
row="$(grep '^LibreAgent' "$WS/LibreCelik/deps.lock")"
printf '%s\n' "${row//LibreAgent/LibreFoo}" >>"$WS/LibreCelik/deps.lock"
expect 1 "unknown dependency row" "unknown dependency 'LibreFoo'" -- "$BD" check --root "$WS/LibreCelik" --no-remote
restore LibreCelik
printf 'LibreMiddleware %s/LibreMiddleware %s\n' "$BUMP_DEPS_URL_BASE" "$(lock_sha LibreLinux LibreMiddleware)" >>"$WS/LibreCelik/deps.lock"
expect 1 "a dependency outside the consumer's graph (LibreCelik locking LibreMiddleware)" 'LibreCelik does not depend on LibreMiddleware' -- \
    "$BD" check --root "$WS/LibreCelik" --no-remote
restore LibreCelik
expect 1 "resolve: unknown name asked for" "names: unknown dependency 'LibreFoo'" -- "$BD" resolve --root "$WS/LibreCelik" --names LibreFoo
expect 1 "resolve: a name the lock does not carry" 'has no LibreMiddleware row' -- "$BD" resolve --root "$WS/LibreCelik" --names LibreMiddleware
expect 0 "resolve: the action's plumbing" -- "$BD" resolve --root "$WS/LibreLinux" --names LibreAgent
assert "resolve prints the lock's LibreAgent and leaves LibreMiddleware out" -- \
    bash -c "grep -qx 'libreagent-sha=$(lock_sha LibreLinux LibreAgent)' '$T/out' \
        && grep -qx 'libremiddleware-wanted=false' '$T/out' && grep -qx 'libreagent-repository=remotes/LibreAgent' '$T/out'"

# ------------------------------------------------- stale / unreachable lock
old_la="$(git -C "$WS/LibreAgent" rev-parse HEAD~1)"
git -C "$WS/LibreAgent" checkout -q -b side HEAD~1
echo side >"$WS/LibreAgent/side.txt"; git -C "$WS/LibreAgent" add side.txt; git -C "$WS/LibreAgent" commit -q -m side
side="$(git -C "$WS/LibreAgent" rev-parse HEAD)"
git -C "$WS/LibreAgent" push -q origin side; git -C "$WS/LibreAgent" checkout -q main
expect 0 "root mode with the network: green control" -- "$BD" check --root "$WS/LibreCelik"
setsha LibreCelik LibreAgent "$side"
expect 1 "stale lock: a commit only on another upstream branch" 'LibreAgent [0-9a-f]+ is not reachable from upstream main' -- "$BD" check --root "$WS/LibreCelik"
restore LibreCelik
setsha LibreCelik LibreAgent "$(printf 'a%.0s' {1..40})"
expect 1 "stale lock: a commit that does not exist upstream" 'LibreAgent a{12} does not exist upstream' -- "$BD" check --root "$WS/LibreCelik"
restore LibreCelik
setsha LibreCelik LibreAgent "$side"
expect 1 "stale lock seen through the workspace clone too" 'RED: LibreCelik: LibreAgent [0-9a-f]+ is not reachable' -- "$BD" check --workspace "$WS"
restore LibreCelik

# ---------------------------------------------------------------- diamond
setsha LibreKDE LibreAgent "$old_la"
expect 0 "an older but reachable lock is fine on its own" -- "$BD" check --root "$WS/LibreKDE"
expect 1 "diamond: LibreKDE and LibreCelik lock different LibreAgent" 'RED: diamond -- LibreAgent is locked at 2 revisions' -- "$BD" check --workspace "$WS"
restore LibreKDE
old_lm="$(git -C "$T/seed/LibreMiddleware" rev-parse HEAD~1)"
setsha LibreLinux LibreMiddleware "$old_lm"
expect 1 "diamond: LibreLinux's LibreMiddleware is not the one its LibreAgent builds" 'RED: LibreLinux: diamond -- LibreLinux locks LibreMiddleware' -- \
    "$BD" check --root "$WS/LibreLinux"
restore LibreLinux

la_root="$(git -C "$WS/LibreAgent" rev-list --max-parents=0 HEAD)"
setsha LibreCelik LibreAgent "$la_root"
expect 0 "a LibreAgent without deps.lock is nothing to LibreCelik, which locks no LibreMiddleware" -- \
    "$BD" check --root "$WS/LibreCelik"
restore LibreCelik
setsha LibreLinux LibreAgent "$la_root"
expect 2 "LibreLinux on a LibreAgent without deps.lock: the diamond cannot be judged" \
    'LibreAgent [0-9a-f]+ has no deps.lock' -- "$BD" check --root "$WS/LibreLinux"
restore LibreLinux
setsha LibreMac LibreAgent "$old_la"
expect 1 "diamond: LibreMac's LibreAgent is not the one its LibreDarwin builds" \
    'RED: LibreMac: diamond -- LibreMac locks LibreAgent [0-9a-f]+ but its LibreDarwin [0-9a-f]+ builds LibreAgent' -- \
    "$BD" check --root "$WS/LibreMac"
restore LibreMac
expect 0 "resolve: LibreMac asks for LibreAgent and LibreDarwin" -- "$BD" resolve --root "$WS/LibreMac"
assert "resolve prints LibreMac's LibreDarwin row" -- \
    grep -qx "libredarwin-sha=$(lock_sha LibreMac LibreDarwin)" "$T/out"

# ---------------------------------------------------- checkout != lock
lock_la="$(lock_sha LibreCelik LibreAgent)"
git clone -q "file://$T/remotes/LibreAgent" "$T/co-lock" && git -C "$T/co-lock" checkout -q "$lock_la"
git clone -q "file://$T/remotes/LibreAgent" "$T/co-old" && git -C "$T/co-old" checkout -q "$old_la"
expect 0 "checkout at the lock" -- "$BD" check --root "$WS/LibreCelik" --no-remote --checkout "LibreAgent=$T/co-lock"
expect 1 "checkout not at the lock" '\(checkout\) is at [0-9a-f]+, deps.lock says' -- "$BD" check --root "$WS/LibreCelik" --no-remote --checkout "LibreAgent=$T/co-old"
echo dirty >>"$T/co-lock/src/la.c"
expect 1 "checkout at the lock with a modified file" 'has modified files' -- "$BD" check --root "$WS/LibreCelik" --no-remote --checkout "LibreAgent=$T/co-lock"
git -C "$T/co-lock" checkout -q -- src/la.c
expect 1 "checkout that is not a git tree" 'is not a git checkout' -- "$BD" check --root "$WS/LibreCelik" --no-remote --checkout "LibreAgent=$T/nope"
expect 1 "checkout for an unknown dependency" "--checkout names unknown dependency 'LibreFoo'" -- "$BD" check --root "$WS/LibreCelik" --no-remote --checkout "LibreFoo=$T/co-lock"
mkdir -p "$T/b-override" "$T/b-fetch/_deps" "$T/b-none"
echo "FETCHCONTENT_SOURCE_DIR_LIBREAGENT:PATH=$T/co-old" >"$T/b-override/CMakeCache.txt"
echo "CMAKE_BUILD_TYPE:STRING=Release" >"$T/b-fetch/CMakeCache.txt"
echo "CMAKE_BUILD_TYPE:STRING=Release" >"$T/b-none/CMakeCache.txt"
expect 1 "build dir whose FETCHCONTENT_SOURCE_DIR is not the lock" 'FETCHCONTENT_SOURCE_DIR_LIBREAGENT of .* is at' -- \
    "$BD" check --root "$WS/LibreCelik" --no-remote --build-dir "$T/b-override"
git clone -q "file://$T/remotes/LibreAgent" "$T/b-fetch/_deps/libreagent-src" && git -C "$T/b-fetch/_deps/libreagent-src" checkout -q "$lock_la"
expect 0 "build dir that fetched the lock" -- "$BD" check --root "$WS/LibreCelik" --no-remote --build-dir "$T/b-fetch"
git -C "$T/b-fetch/_deps/libreagent-src" checkout -q "$old_la"
expect 1 "build dir that fetched something else" '\(fetched by .*\) is at' -- "$BD" check --root "$WS/LibreCelik" --no-remote --build-dir "$T/b-fetch"
expect 2 "build dir that built nothing from source cannot be judged" 'none was found' -- \
    "$BD" check --root "$WS/LibreCelik" --no-remote --build-dir "$T/b-none"

# ------------------------------------------------------------------ --tag
# The train freezes the locks at upstream main, then tags upstream at exactly
# that commit: `check --tag` holds the commit, and nothing but the commit.
assert "the lock written by to-head carries three columns" -- \
    bash -c "! grep -Ev '^[[:space:]]*(#|$)' '$WS/LibreCelik/deps.lock' | awk 'NF != 3 { bad = 1 } END { exit !bad }'"
expect 1 "--tag before upstream tagged" 'has no tag 5.0.0 upstream' -- "$BD" check --root "$WS/LibreCelik" --tag 5.0.0
for R in LibreMiddleware LibreAgent; do
    git -C "$WS/$R" pull -q --ff-only origin main
    git -C "$WS/$R" tag -a 5.0.0 -m "$R 5.0.0" && git -C "$WS/$R" push -q origin 5.0.0
done
expect 0 "--tag: the lock to-head wrote is the (annotated, peeled) tag" -- "$BD" check --root "$WS/LibreCelik" --tag 5.0.0
assert "and the lock was not rewritten to get there" -- test -z "$(git -C "$WS/LibreCelik" status --porcelain)"
expect 1 "--tag: a version upstream never tagged" 'has no tag 5.0.1 upstream' -- "$BD" check --root "$WS/LibreCelik" --tag 5.0.1
setsha LibreCelik LibreAgent "$old_la"
expect 1 "--tag: the locked commit is not the tag's" 'locked [0-9a-f]+ but 5.0.0 is' -- "$BD" check --root "$WS/LibreCelik" --tag 5.0.0
restore LibreCelik
perturb LibreCelik '/^LibreAgent/s/$/  5.0.0/'
expect 1 "--tag: a fourth column naming the very tag is still refused" 'drop column 4' -- "$BD" check --root "$WS/LibreCelik" --tag 5.0.0
restore LibreCelik
expect 2 "--tag with --no-remote cannot be judged" '--tag needs the network' -- "$BD" check --root "$WS/LibreCelik" --tag 5.0.0 --no-remote
expect 2 "to-tag is gone" "unknown command 'to-tag'" -- "$BD" to-tag 5.0.0 LibreCelik --workspace "$WS"

# --------------------------------------------------- vendored contract
expect 0 "LibreMac contract matches LibreAgent at the lock" -- "$BD" check --root "$WS/LibreMac"
echo ' ' >>"$WS/LibreMac/$CONTRACT/wire-vocabulary.json"
expect 1 "LibreMac contract edited by hand" 'RED: .*wire-vocabulary.json differs' -- "$BD" check --root "$WS/LibreMac"
expect 1 "LibreMac contract edited by hand, judged against a LibreAgent checkout" 'RED: .*wire-vocabulary.json differs' -- \
    "$BD" check --root "$WS/LibreMac" --no-remote --checkout "LibreAgent=$T/co-lock"
restore LibreMac

# ------------------------------------------------- to-head refuses to guess
echo "# local edit" >>"$WS/LibreKDE/deps.lock"
expect 2 "to-head refuses a lock with uncommitted edits" 'uncommitted changes in deps.lock' -- "$BD" to-head LibreKDE --workspace "$WS"
restore LibreKDE
upstream_commit LibreKDE README "someone else"
expect 2 "to-head refuses a consumer that does not contain upstream main" 'does not contain upstream main' -- "$BD" to-head LibreKDE --workspace "$WS"
assert "and wrote nothing" -- test "$(git -C "$WS/LibreKDE" status --porcelain)" = ""
expect 2 "to-head refuses a name that is not a consumer" "'LibreFoo' is not a consumer" -- "$BD" to-head LibreFoo --workspace "$WS"

[ "$fail" = 0 ] || { echo "bump-deps selftest FAILED"; exit 1; }
echo "selftest: $n cases, $r red-proved"
