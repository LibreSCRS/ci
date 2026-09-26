#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# lmac-contract-regen.selftest.sh -- a fake LibreAgent (as a work tree and as a
# git dir read at a revision) and a fake LibreMac contract directory.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RG="$here/lmac-contract-regen.sh"
unset REPO_ROOT GITHUB_WORKSPACE

T="$(mktemp -d "${TMPDIR:-/var/tmp}/lcr-selftest-XXXXXX")" || { echo "cannot create temp dir" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --global user.name Selftest
git config --global user.email selftest@example.invalid
git config --global commit.gpgsign false

C=LibreMacAgentClient/Tests/LibreMacAgentClientTests/Contract
P=include/LibreSCRS/Agent/operations/PromptPolicy.h
LA="$T/LibreAgent" MAC="$T/LibreMac"
mkdir -p "$LA/wire" "$LA/$(dirname "$P")" "$MAC/$C"
echo '{"schema":1,"vocabularies":{"a":1}}' >"$LA/wire/wire-vocabulary.json"
printf '%s\n' "inline constexpr auto kMaxSequentialPromptBudget = x; // budget-ms: 300'000" >"$LA/$P"
git -C "$LA" init -q && git -C "$LA" add -A && git -C "$LA" commit -q -m one
rev1="$(git -C "$LA" rev-parse HEAD)"
echo '{"schema":1,"vocabularies":{"a":2}}' >"$LA/wire/wire-vocabulary.json"
git -C "$LA" commit -q -am two
echo '{}' >"$MAC/$C/wire-vocabulary.json"; echo 'max-sequential-ms 1' >"$MAC/$C/prompt-policy.txt"

n=0 r=0 fail=0
expect() {  # RC DESC PATTERN -- cmd...
    local want=$1 desc=$2 pat=$3 got; shift 4
    "$@" </dev/null >"$T/out" 2>&1; got=$?
    n=$((n + 1))
    if [ "$got" = "$want" ] && { [ -z "$pat" ] || grep -Eq -- "$pat" "$T/out"; }; then
        [ "$want" = 0 ] || r=$((r + 1)); echo "ok   $desc (rc=$got)"
    else
        fail=1; echo "FAIL $desc: want rc=$want${pat:+ and /$pat/}, got rc=$got"; sed 's/^/     | /' "$T/out"
    fi
}
assert() { local desc=$1; shift 2; n=$((n + 1)); if "$@"; then echo "ok   $desc"; else fail=1; echo "FAIL $desc"; fi; }

expect 1 "check before regenerating: both files differ" "prompt-policy.txt differs" -- "$RG" --root "$MAC" --la-src "$LA" --check
expect 0 "regenerate from a work tree" "" -- "$RG" --root "$MAC" --la-src "$LA"
assert "vocabulary is a byte copy" -- cmp -s "$MAC/$C/wire-vocabulary.json" "$LA/wire/wire-vocabulary.json"
assert "budget read from the marker, digit separator dropped" -- grep -qx 'max-sequential-ms 300000' "$MAC/$C/prompt-policy.txt"
expect 0 "check after regenerating" "" -- "$RG" --root "$MAC" --la-src "$LA" --check
expect 1 "check against an older revision read from git" "wire-vocabulary.json differs" -- \
    "$RG" --root "$MAC" --la-repo "$LA/.git" --rev "$rev1" --check
expect 0 "check against HEAD read from git agrees with the work tree" "" -- \
    "$RG" --root "$MAC" --la-repo "$LA/.git" --rev HEAD --check
echo ' ' >>"$MAC/$C/prompt-policy.txt"
expect 1 "hand-edited prompt-policy.txt" "RED: .*prompt-policy.txt differs" -- "$RG" --root "$MAC" --la-src "$LA" --check
"$RG" --root "$MAC" --la-src "$LA" >/dev/null
command cp -f "$LA/$P" "$T/policy.bak"
echo "// budget-ms: 1" >>"$LA/$P"
expect 2 "two budget markers is a guess, not a contract" "2 '// budget-ms:' markers" -- "$RG" --root "$MAC" --la-src "$LA" --check
echo "no marker" >"$LA/$P"
expect 2 "no budget marker" "0 '// budget-ms:' markers" -- "$RG" --root "$MAC" --la-src "$LA" --check
command cp -f "$T/policy.bak" "$LA/$P"
expect 2 "agent source without the vocabulary" "cannot read wire/wire-vocabulary.json" -- \
    "$RG" --root "$MAC" --la-src "$T" --check
expect 2 "a revision the agent repo does not have" "has no commit" -- \
    "$RG" --root "$MAC" --la-repo "$LA/.git" --rev "$(printf 'b%.0s' {1..40})" --check
expect 2 "root that is not LibreMac" "not a LibreMac checkout" -- "$RG" --root "$LA" --la-src "$LA" --check
expect 2 "both source shapes at once" "exactly one of" -- \
    "$RG" --root "$MAC" --la-src "$LA" --la-repo "$LA/.git" --rev HEAD --check

[ "$fail" = 0 ] || { echo "lmac-contract-regen selftest FAILED"; exit 1; }
echo "selftest: $n cases, $r red-proved"
