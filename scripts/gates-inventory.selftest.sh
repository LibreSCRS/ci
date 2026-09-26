#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# gates-inventory.selftest.sh -- the inventory lists exactly the gates the
# workflows run, both ways they can be run, and --diff is red on any change.
#
# The rows are compared whole against an expected table, so a gate the parser
# misses (a script under a checkout subdirectory, a `uses:` step resolved
# through the profile) and a gate it invents (a name in a comment) are both
# a failing case, not a count that happens to match.
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INV="$here/gates-inventory.py"
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: python3 cannot import yaml -- cannot judge" >&2; exit 2; }
T="$(mktemp -d "/var/tmp/gates-inventory-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
out="$T/out"
fails=0
cases=0
red=0
SHA=1111111111111111111111111111111111111111

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
        sed -n '1,20p' "$out" | sed 's/^/  | /'
        fails=1
    fi
}
same() {  # same <label> <expected-file>: $out equals it, byte for byte
    cases=$((cases + 1))
    if cmp -s "$2" "$out"; then printf 'ok    %s\n' "$1"
    else printf 'FAIL  %s\n' "$1"; diff "$2" "$out" | sed 's/^/  | /'; fails=1; fi
}
repo() {  # repo <name> <workflow-file>: stdin is the workflow
    local d="$T/ws/$1"
    mkdir -p "$d/.github/workflows"
    cat > "$d/.github/workflows/$2"
    git -C "$d" init -q 2>/dev/null
    git -C "$d" add -A
    git -C "$d" -c user.email=s@e -c user.name=s commit -qm w
}

# A LibreSCRS/ci checkout of its own: the real profile runner, fixture profiles,
# and one other action whose scripts are named in its action.yml.
mkdir -p "$T/ci/scripts" "$T/ci/profiles" "$T/ci/actions/release-seal"
cp "$here/run-gates.py" "$T/ci/scripts/"
printf 'check-format-scope\ncheck-workflows\ntest-manifest-gate build\n' > "$T/ci/profiles/After.txt"
# shellcheck disable=SC2016  # the action's own shell expands it, not this one
printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: bash "$GITHUB_ACTION_PATH/../../scripts/seal.sh"\n' \
    > "$T/ci/actions/release-seal/action.yml"

repo Before ci.yml <<'YML'
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./ci/scripts/check-format-scope.sh
      - run: |
          # ci/scripts/retired-gate.sh used to run here
          python3 tools/dup-scan.py --repo x
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - if: matrix.extra
        run: ci/scripts/test-manifest-gate.sh --check build linux && ci/scripts/test-manifest-gate.selftest.sh
YML
repo Before release.yml <<'YML'
on:
  push:
    tags: ['*']
jobs:
  seal:
    if: github.repository == 'x/y'
    runs-on: ubuntu-latest
    steps:
      - run: _src/ci/scripts/check-release-assets.sh --staged artifacts
YML
repo After ci.yml <<YML
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: LibreSCRS/ci/actions/gates@$SHA
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: LibreSCRS/ci/actions/gates@$SHA
        with:
          phase: build
      - uses: LibreSCRS/ci/actions/release-seal@$SHA
YML

inv() { (cd "$T" && python3 "$INV" --ci-root "$T/ci" "$@") >"$out" 2>&1; echo $?; }

tab=$'\t'
{
printf 'repo\tgate\tscript\tworkflow\tjob\tevents\tcondition\tvia\n'
printf 'After\tcheck-format-scope\tLibreSCRS/ci:scripts/check-format-scope.sh\tci.yml\tlint\tpush\t-\taction:gates:static\n'
printf 'After\tcheck-workflows\tLibreSCRS/ci:scripts/check-workflows.py\tci.yml\tlint\tpush\t-\taction:gates:static\n'
printf 'After\tseal\tLibreSCRS/ci:scripts/seal.sh\tci.yml\tbuild\tpush\t-\taction:release-seal\n'
printf 'After\ttest-manifest-gate\tLibreSCRS/ci:scripts/test-manifest-gate.sh\tci.yml\tbuild\tpush\t-\taction:gates:build\n'
printf 'Before\tcheck-format-scope\tci/scripts/check-format-scope.sh\tci.yml\tlint\tpull_request,push\t-\tinline\n'
printf 'Before\tcheck-release-assets\t_src/ci/scripts/check-release-assets.sh\trelease.yml\tseal\tpush:tags\tgithub.repository == %sx/y%s\tinline\n' "'" "'"
printf 'Before\tdup-scan\ttools/dup-scan.py\tci.yml\tlint\tpull_request,push\t-\tinline\n'
printf 'Before\ttest-manifest-gate\tci/scripts/test-manifest-gate.sh\tci.yml\tbuild\tpull_request,push\tmatrix.extra\tinline\n'
printf 'Before\ttest-manifest-gate.selftest\tci/scripts/test-manifest-gate.selftest.sh\tci.yml\tbuild\tpull_request,push\tmatrix.extra\tinline\n'
} > "$T/expected.tsv"
: "$tab"

expect "1 the inventory lists" 0 "$(inv --workspace "$T/ws" --repos Before,After)"
same "1b every row, and only those: inline, under a subdirectory, through the profile and an action; not a comment" \
    "$T/expected.tsv"

# --rev reads the commit, not the working tree
printf 'jobs: {}\n' > "$T/ws/Before/.github/workflows/ci.yml"
expect "2 --rev HEAD reads what is committed" 0 "$(inv --workspace "$T/ws" --repos Before,After --rev HEAD)"
same "2b the working-tree edit is invisible to --rev" "$T/expected.tsv"
git -C "$T/ws/Before" checkout -q -- .github/workflows/ci.yml

# --diff
inv --workspace "$T/ws" --repos Before > /dev/null; cp "$out" "$T/before.tsv"
inv --workspace "$T/ws" --repos After > /dev/null; cp "$out" "$T/after.tsv"
expect "3 --diff of two different lists is red and names both sides" 1 \
    "$( (python3 "$INV" --diff "$T/before.tsv" "$T/after.tsv") >"$out" 2>&1; echo $?)" \
    "-${tab}Before${tab}dup-scan" "+${tab}After${tab}check-workflows" "row(s) differ"
expect "4 --diff of a list against itself is green" 0 \
    "$( (python3 "$INV" --diff "$T/before.tsv" "$T/before.tsv") >"$out" 2>&1; echo $?)" "0 row(s) differ"

# refusing to judge
rm "$T/ci/profiles/After.txt"
expect "5 a gates step with no profile cannot be listed" 2 "$(inv --workspace "$T/ws" --repos After)" \
    "no profile for 'After'"
repo Unknown ci.yml <<YML
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: LibreSCRS/ci/actions/nonesuch@$SHA
YML
expect "6 an action LibreSCRS/ci does not provide cannot be listed" 2 \
    "$(inv --workspace "$T/ws" --repos Unknown)" "actions/nonesuch"
mkdir -p "$T/ws/Empty"; git -C "$T/ws/Empty" init -q
expect "7 a repository with no workflows cannot be listed" 2 "$(inv --workspace "$T/ws" --repos Empty)" \
    "no workflows"
repo Broken ci.yml <<'YML'
on: [push
YML
expect "8 unloadable YAML cannot be listed" 2 "$(inv --workspace "$T/ws" --repos Broken)" "not loadable YAML"
expect "9 --diff of a file that is not an inventory cannot judge" 2 \
    "$( (python3 "$INV" --diff "$T/expected.tsv" "$T/ci/actions/release-seal/action.yml") >"$out" 2>&1; echo $?)" \
    "header is not"

[ "$fails" = 0 ] && echo "gates-inventory selftest: all cases behave" || echo "gates-inventory selftest: FAILED"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit "$fails"
