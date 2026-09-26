#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# lmac-contract-regen.sh -- regenerate (or check) the agent contract LibreMac
# vendors, from LibreAgent at one exact revision.
#
# LibreMac speaks the agent's wire without linking the agent, so it carries a
# copy of two facts the agent owns:
#
#   wire-vocabulary.json  byte copy of LibreAgent wire/wire-vocabulary.json
#   prompt-policy.txt     `max-sequential-ms <n>`, where <n> is the number the
#                         agent writes after `// budget-ms:` in
#                         include/LibreSCRS/Agent/operations/PromptPolicy.h
#
# Both are derived, never edited: `bump-deps to-head|to-tag` calls this in the
# same commit that moves LibreMac's LibreAgent row in deps.lock, and
# `bump-deps check` calls it with --check, so "the vendored copy is the agent's
# contract at the locked revision" is measured on bytes, not on a recorded
# revision string.
#
# Usage:
#   lmac-contract-regen.sh [--root DIR] --la-src DIR            [--check]
#   lmac-contract-regen.sh [--root DIR] --la-repo GITDIR --rev SHA [--check]
#
#   --root     the LibreMac checkout (default $REPO_ROOT, then
#              $GITHUB_WORKSPACE, then the git toplevel of the CWD)
#   --la-src   a LibreAgent working tree (for CI: the checkout-deps path)
#   --la-repo  a LibreAgent git dir, read at --rev without a checkout
#   --check    compare instead of write
#
# Exit codes: 0 written / matches, 1 --check found a difference,
#             2 cannot produce the contract (missing input, no or several
#             budget markers, bad usage).
set -uo pipefail

CONTRACT_DIR=LibreMacAgentClient/Tests/LibreMacAgentClientTests/Contract
LA_VOCAB=wire/wire-vocabulary.json
LA_POLICY=include/LibreSCRS/Agent/operations/PromptPolicy.h

die2() { echo "lmac-contract-regen: $*" >&2; exit 2; }

root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
la_src="" la_repo="" rev="" check=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) root="${2:-}"; shift 2 ;;
        --la-src) la_src="${2:-}"; shift 2 ;;
        --la-repo) la_repo="${2:-}"; shift 2 ;;
        --rev) rev="${2:-}"; shift 2 ;;
        --check) check=1; shift ;;
        *) die2 "unknown argument '$1'" ;;
    esac
done
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die2 "no --root, REPO_ROOT or GITHUB_WORKSPACE, and the CWD is not a git checkout"
[ -d "$root/$CONTRACT_DIR" ] || die2 "$root has no $CONTRACT_DIR -- not a LibreMac checkout"

# One reader for both input shapes, so --la-src and --la-repo cannot drift.
read_la() {
    if [ -n "$la_src" ]; then
        cat -- "$la_src/$1"
    else
        git -C "$la_repo" show "$rev:$1"
    fi
}
if [ -n "$la_src" ] && [ -z "$la_repo" ] && [ -z "$rev" ]; then
    [ -d "$la_src" ] || die2 "--la-src $la_src is not a directory"
elif [ -z "$la_src" ] && [ -n "$la_repo" ] && [ -n "$rev" ]; then
    git -C "$la_repo" cat-file -e "$rev^{commit}" 2>/dev/null \
        || die2 "$la_repo has no commit $rev"
else
    die2 "give exactly one of --la-src DIR or --la-repo GITDIR --rev SHA"
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/lmac-contract.XXXXXX")" \
    || die2 "cannot create a temporary directory"
trap 'rm -rf "$work"' EXIT

read_la "$LA_VOCAB" >"$work/wire-vocabulary.json" 2>/dev/null \
    || die2 "cannot read $LA_VOCAB from the agent source"
[ -s "$work/wire-vocabulary.json" ] || die2 "$LA_VOCAB is empty in the agent source"
read_la "$LA_POLICY" >"$work/policy.h" 2>/dev/null \
    || die2 "cannot read $LA_POLICY from the agent source"

# Exactly one marker. Two would make "which one is the budget" a guess, and a
# guess here is a silent contract change; none means the agent stopped
# declaring the number this client is held to.
mapfile -t budgets < <(sed -n "s#.*// budget-ms:[[:space:]]*\([0-9][0-9']*\).*#\1#p" "$work/policy.h" | tr -d "'")
[ "${#budgets[@]}" -eq 1 ] \
    || die2 "$LA_POLICY carries ${#budgets[@]} '// budget-ms:' markers, want exactly 1"
printf 'max-sequential-ms %s\n' "${budgets[0]}" >"$work/prompt-policy.txt"

rc=0
for f in wire-vocabulary.json prompt-policy.txt; do
    dst="$root/$CONTRACT_DIR/$f"
    if [ "$check" = 1 ]; then
        if cmp -s "$work/$f" "$dst"; then
            echo "ok: $CONTRACT_DIR/$f matches the agent source"
        else
            echo "RED: $CONTRACT_DIR/$f differs from the agent source -- regenerate it with bump-deps, do not edit it"
            rc=1
        fi
    else
        cat -- "$work/$f" >"$dst" || die2 "cannot write $dst"
    fi
done
exit "$rc"
