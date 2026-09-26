#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC1007,SC2010,SC2012,SC2015,SC2016,SC2028,SC2181  # fixture text is literal on purpose; A && B || C report lines
# Self-test for check-release-assets.sh -- all three arms, the shared
# release-publish action as a wired step, and the consumer-root contract.
#
# --staged is judged over fixture DIRECTORIES of real files, because bytes on
# disk are what it measures; --wired over workflow fragments; --published over
# a GH_ASSETS_JSON fixture, never the network -- a self-test that needs the
# network quietly leaves CI the first day it has none.
#
# S0 and W1 are the anti-vacuum cases: without them a check that always says 1
# passes every red case below. S8-S10, W4, B7 and B8 assert 2, not 1: "I could
# not judge" and "I judged and found a fault" must never be spelled the same.
set -u

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/check-release-assets.sh"
if [ ! -f "$subject" ]; then
    echo "FAIL  subject missing: $subject does not exist -- nothing to prove" >&2
    exit 1
fi

work="$(mktemp -d "${TMPDIR:-/var/tmp}/check-release-assets.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

cases=0
red=0
fails=0

# check <name> <want-rc> <text-the-output-must-carry|-> -- <command...>
check() {
    local name="$1" want="$2" needle="$3"
    shift 4
    cases=$((cases + 1))
    [ "$want" != 0 ] && red=$((red + 1))
    local out got
    out="$("$@" 2>&1)"
    got=$?
    if [ "$got" != "$want" ]; then
        printf 'FAIL  %s: rc=%s, want %s\n' "$name" "$got" "$want"
        printf '%s\n' "$out" | sed 's/^/  | /'
        fails=$((fails + 1))
        return
    fi
    if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
        printf 'FAIL  %s: rc=%s as wanted, but the output does not name "%s"\n' \
            "$name" "$got" "$needle"
        printf '%s\n' "$out" | sed 's/^/  | /'
        fails=$((fails + 1))
        return
    fi
    printf 'ok    %s (rc=%s)\n' "$name" "$got"
}

# changed <what> <before> <after>: a perturbation that changed nothing proves
# nothing, so each one is asserted to have moved the fixture.
changed() {
    if cmp -s "$2" "$3"; then
        echo "FAIL  $1: the perturbation did not change the fixture"
        fails=$((fails + 1))
    fi
}

# ---------------------------------------------------------------- the data --
decl="$work/release-assets.txt"
cat > "$decl" <<'TXT'
# SPDX-License-Identifier: LGPL-2.1-or-later
# fixture: the middleware's shape
*.debian13.deb        binary packages built in a Debian 13 container
*.fedora43.rpm        binary packages built in a Fedora 43 container
*.orig.tar.gz         the deterministic source tarball
SHA256SUMS            checksums over every other asset
*.sigstore.json       cosign keyless signature bundle, one per asset
TXT
empty="$work/empty-assets.txt"
printf '%s\n' '# SPDX-License-Identifier: LGPL-2.1-or-later' \
    '# Deliberately empty: notes and nothing else.' > "$empty"

good="$work/good"
mkdir -p "$good"
for f in liblibrescrs5_5.0.0-1_amd64.debian13.deb librescrs-middleware-5.0.0-1.x86_64.fedora43.rpm \
         librescrs-middleware_5.0.0.orig.tar.gz SHA256SUMS \
         liblibrescrs5_5.0.0-1_amd64.debian13.deb.sigstore.json SHA256SUMS.sigstore.json; do
    : > "$good/$f"
done
listing() { (cd "$1" && ls -A | sort); }

staged() { RELEASE_ASSETS_FILE="$1" bash "$subject" --staged "${@:2}"; }

# ---------------------------------------------------------------- --staged --
check "S0 staging matches the declared set" 0 - -- staged "$decl" "$good"

d="$work/s1"; command cp -a "$good" "$d"; rm "$d/SHA256SUMS"
changed "S1" <(listing "$good") <(listing "$d")
check "S1 a declared glob has no staged file" 1 "glob SHA256SUMS" -- staged "$decl" "$d"

d="$work/s2"; command cp -a "$good" "$d"; : > "$d/LibreCelik-5.0.0-x86_64.AppImage"
changed "S2" <(listing "$good") <(listing "$d")
check "S2 a staged file matches no glob" 1 "LibreCelik-5.0.0-x86_64.AppImage" -- staged "$decl" "$d"

d="$work/s3"; command cp -a "$good" "$d"
mv "$d/liblibrescrs5_5.0.0-1_amd64.debian13.deb" "$d/liblibrescrs5_5.0.0-1_amd64.deb"
changed "S3" <(listing "$good") <(listing "$d")
check "S3 a package without its distribution slug" 1 "liblibrescrs5_5.0.0-1_amd64.deb" -- staged "$decl" "$d"

d="$work/s4"; command cp -a "$good" "$d"; mkdir "$d/debian13-artifacts"
changed "S4" <(listing "$good") <(listing "$d")
check "S4 a subdirectory in staging is named" 1 "debian13-artifacts is a directory" -- staged "$decl" "$d"

d="$work/s5"; mkdir -p "$d"
check "S5 empty staging against a non-empty declaration" 1 "nothing" -- staged "$decl" "$d"

check "S6 no path, empty declaration" 0 - -- staged "$empty"

check "S7 no path, non-empty declaration" 1 "no path" -- staged "$decl"

check "S8 a staging directory that does not exist" 2 "does not exist" -- staged "$decl" "$work/nowhere"

check "S9 no declaration file" 2 "release-assets.txt" -- staged "$work/absent/release-assets.txt" "$good"

dup="$work/dup.txt"; command cp -f "$decl" "$dup"
printf '%s\n' 'SHA256SUMS            the same glob, twice' >> "$dup"
changed "S10" "$decl" "$dup"
check "S10 a glob declared twice" 2 "SHA256SUMS" -- staged "$dup" "$good"

# ----------------------------------------------------------------- --wired --
wf_head() { printf '%s\n' 'name: Release' 'on:' '  push:' '    tags: ["*"]' 'jobs:'; }
staged_step='      - name: The staged asset set is the set this repository declares
        run: _src/ci/scripts/check-release-assets.sh --staged artifacts'
create_step='      - name: Create GitHub release
        run: |
          gh release create "$TAG" --verify-tag artifacts/*'

w="$work/w1.yml"
{ wf_head; printf '%s\n' '  release:' '    runs-on: ubuntu-latest' '    steps:' \
    "$staged_step" "$create_step"; } > "$w"
wired() { RELEASE_WORKFLOW="$1" bash "$subject" --wired; }
check "W1 staged step before gh release create" 0 - -- wired "$w"

w2="$work/w2.yml"
{ wf_head; printf '%s\n' '  release:' '    runs-on: ubuntu-latest' '    steps:' \
    "$create_step" "$staged_step"; } > "$w2"
changed "W2" "$w" "$w2"
check "W2 staged step after gh release create" 1 "after" -- wired "$w2"

w3="$work/w3.yml"
{ wf_head; printf '%s\n' '  lint:' '    runs-on: ubuntu-latest' '    steps:' "$staged_step" \
    '  release:' '    runs-on: ubuntu-latest' '    steps:' "$create_step"; } > "$w3"
check "W3 staged step in another job" 1 "release" -- wired "$w3"

w4="$work/w4.yml"
{ wf_head; printf '%s\n' '  build:' '    runs-on: ubuntu-latest' '    steps:' "$staged_step"; } > "$w4"
check "W4 no gh release create anywhere" 2 "gh release create" -- wired "$w4"

# W5-W8 -- a --staged step that cannot fail the job is not wired. Each keeps
# the command in the file and takes away its power to stop the release.
w5="$work/w5.yml"
{ wf_head; printf '%s\n' '  release:' '    runs-on: ubuntu-latest' '    steps:' \
    '      - name: Only a comment' \
    '        run: |' \
    '          # _src/ci/scripts/check-release-assets.sh --staged artifacts' \
    '          true' "$create_step"; } > "$w5"
check "W5 staged step present only as a comment" 1 "no check-release-assets.sh --staged" -- wired "$w5"

w6="$work/w6.yml"
{ wf_head; printf '%s\n' '  release:' '    runs-on: ubuntu-latest' '    steps:' \
    "$staged_step" '        continue-on-error: true' "$create_step"; } > "$w6"
changed "W6" "$w" "$w6"
check "W6 staged step with continue-on-error" 1 "continue-on-error" -- wired "$w6"

w7="$work/w7.yml"
{ wf_head; printf '%s\n' '  release:' '    runs-on: ubuntu-latest' '    steps:' \
    "$staged_step" '        if: false' "$create_step"; } > "$w7"
check "W7 staged step behind an if: condition" 1 "if:" -- wired "$w7"

w8="$w.or-true.yml"
sed 's|--staged artifacts$|--staged artifacts \|\| true|' "$w" > "$w8"
changed "W8" "$w" "$w8"
check "W8 staged call whose failure is swallowed by ||" 1 "||" -- wired "$w8"

# ------------------------------------------------------------- --published --
names_json() {  # names_json <draft> <name...>
    local draft="$1" first=1 n
    shift
    printf '{"isDraft": %s, "assets": [' "$draft"
    for n in "$@"; do
        [ "$first" = 1 ] || printf ', '
        first=0
        printf '{"name": "%s"}' "$n"
    done
    printf ']}\n'
}
mapfile -t good_names < <(listing "$good")
published() {  # published <declaration> <json> [--strict]
    local flag=--published
    [ "${3:-}" = --strict ] && flag=--published-strict
    RELEASE_ASSETS_FILE="$1" GH_ASSETS_JSON="$2" bash "$subject" "$flag" 5.0.0
}
all="$work/b-all.json"; names_json false "${good_names[@]}" > "$all"

mapfile -t b1_names < <(printf '%s\n' "${good_names[@]}" | grep -vx SHA256SUMS)
b="$work/b1.json"; names_json false "${b1_names[@]}" > "$b"
changed "B1" "$all" "$b"
check "B1 published set lacks SHA256SUMS" 1 "glob SHA256SUMS" -- published "$decl" "$b"

b="$work/b2.json"; names_json false "${good_names[@]}" LibreCelik-5.0.0-macos.dmg > "$b"
check "B2 published set carries a foreign asset" 1 "LibreCelik-5.0.0-macos.dmg" -- published "$decl" "$b"

b="$work/b3.json"
mapfile -t b3_names < <(printf '%s\n' "${good_names[@]}" | sed 's/\.debian13\.deb$/.deb/')
names_json false "${b3_names[@]}" > "$b"
changed "B3" "$all" "$b"
check "B3 published package without its slug" 1 "liblibrescrs5_5.0.0-1_amd64.deb" -- published "$decl" "$b"

b="$work/b4.json"; names_json false > "$b"
check "B4 no assets against a non-empty declaration" 1 "no assets" -- published "$decl" "$b"

check "B5 no assets against an empty declaration" 0 - -- published "$empty" "$b"

b="$work/b6.json"; names_json true "${good_names[@]}" > "$b"
check "B6 a draft is judged, and says so" 0 "DRAFT=yes" -- published "$decl" "$b"
if ! published "$decl" "$b" 2>&1 | grep -qF '::notice::judged a DRAFT release'; then
    echo "FAIL  B6 the draft verdict carries no ::notice::"; fails=$((fails + 1))
fi

check "B7 a draft under --published-strict is not evidence" 2 "DRAFT" -- published "$decl" "$b" --strict

check "B8 no assets fixture to read" 2 "GH_ASSETS_JSON" -- published "$decl" "$work/absent.json"

# B9 -- an empty tag: gh would answer with the latest release, which is
# evidence about a different release.
check "B9 an empty tag is a usage error, not the latest release" 2 "usage" -- \
    env RELEASE_ASSETS_FILE="$decl" GH_ASSETS_JSON="$all" bash "$subject" --published ""

# ------------------------------------------------ the shared publish action --
# A consumer's release workflow no longer runs gh release create itself: it
# calls the shared action, which runs --staged first. W9-W11 are the consumer
# side; A1-A2 hold the action's own file to that order through the same arm.
sha=0123456789abcdef0123456789abcdef01234567
shared_step="      - uses: LibreSCRS/ci/actions/release-publish@$sha"
w9="$work/w9.yml"
{ wf_head; printf '%s\n' '  publish:' '    runs-on: ubuntu-latest' '    steps:' "$shared_step" \
    '        with:' '          mode: publish'; } > "$w9"
check "W9 the shared publish action, pinned by commit" 0 - -- wired "$w9"

w10="$work/w10.yml"
{ wf_head; printf '%s\n' '  publish:' '    runs-on: ubuntu-latest' '    steps:' "$shared_step" \
    '        continue-on-error: true'; } > "$w10"
changed "W10" "$w9" "$w10"
check "W10 the shared action behind continue-on-error" 1 "continue-on-error" -- wired "$w10"

w11="$work/w11.yml"
sed "s|@$sha|@v1|" "$w9" > "$w11"
changed "W11" "$w9" "$w11"
check "W11 the shared action by a movable tag is not recognised" 2 "cannot judge" -- wired "$w11"

action="$here/../actions/release-publish/action.yml"
check "A1 the shared action's own file runs --staged before creating" 0 - -- wired "$action"
a2="$work/a2.yml"
python3 - "$action" "$a2" <<'PY' || { echo "FAIL  A2: could not build the perturbed action"; fails=$((fails + 1)); }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["runs"]["steps"]
st = [i for i, s in enumerate(steps) if "--staged" in str(s.get("run", ""))]
cr = [i for i, s in enumerate(steps) if "gh release create" in str(s.get("run", ""))]
assert st and cr and st[0] < cr[0], (st, cr)
steps.insert(cr[0], steps.pop(st[0]))  # move --staged to just after the create
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
check "A2 the action with --staged moved after the create" 1 "after gh release create" -- wired "$a2"

# ------------------------------------------------------ the consumer's root --
# The tree judged is REPO_ROOT, never where the script lives: on a runner the
# script sits in the shared-gates checkout, and a default derived from its own
# path would judge that repository instead of the consumer.
cons="$work/consumer"; mkdir -p "$cons/ci"; command cp -f "$decl" "$cons/ci/release-assets.txt"
decoy="$work/decoy"; mkdir -p "$decoy/ci"; command cp -f "$empty" "$decoy/ci/release-assets.txt"
check "R1 REPO_ROOT names the declaration, from a foreign cwd" 0 - -- \
    env -u RELEASE_ASSETS_FILE REPO_ROOT="$cons" GITHUB_WORKSPACE="$decoy" \
    bash -c 'cd / && bash "$1" --staged "$2"' _ "$subject" "$good"
check "R2 the same staging against the decoy's empty declaration" 1 "matches no glob" -- \
    env -u RELEASE_ASSETS_FILE REPO_ROOT="$decoy" \
    bash -c 'cd / && bash "$1" --staged "$2"' _ "$subject" "$good"
check "R3 no REPO_ROOT, no workspace, no git checkout" 2 "REPO_ROOT" -- \
    env -u RELEASE_ASSETS_FILE -u REPO_ROOT -u GITHUB_WORKSPACE \
    bash -c 'cd / && bash "$1" --staged "$2"' _ "$subject" "$good"

if [ "$fails" -eq 0 ]; then
    echo "check-release-assets selftest: all cases passed"
else
    echo "check-release-assets selftest: $fails case(s) failed"
fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fails" -eq 0 ]
