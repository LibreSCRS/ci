#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC1007,SC2010,SC2012,SC2015,SC2016,SC2028,SC2181  # fixture text is literal on purpose; A && B || C report lines
# Self-test for check-release-assets.sh -- both arms and the consumer-root
# contract.
#
# --staged is judged over fixture DIRECTORIES of real files, because bytes on
# disk are what it measures; --published over
# a GH_ASSETS_JSON fixture, never the network -- a self-test that needs the
# network quietly leaves CI the first day it has none.
#
# S0 is the anti-vacuum case: without them a check that always says 1
# passes every red case below. S8-S10, B7 and B8 assert 2, not 1: "I could
# not judge" and "I judged and found a fault" must never be spelled the same.
set -u

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/check-release-assets.sh"
if [ ! -f "$subject" ]; then
    echo "FAIL  subject missing: $subject does not exist -- nothing to prove" >&2
    exit 1
fi

work="$(mktemp -d "/var/tmp/check-release-assets.XXXXXX")" || exit 2
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
