#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# check-version.sh [--version <v>] [--arms <a,b,...>] [--min <n>] [--verbose]
# check-version.sh --section <v>
# check-version.sh --list
#
# One question, four arms: does everything in this tree that states a version
# state the one in VERSION, and does the release it is heading for agree?
#
#   lockstep  the CHANGELOG has a non-empty section for <v> (default: the first
#             line of VERSION), and VERSION says <v>. The release preflight
#             passes the tag's version; the per-push gate passes nothing.
#   floors    every first-party find_package()/find_dependency() floor names
#             VERSION's major (whole-floor for the package this tree ships).
#   stamp     what project() stamps follows VERSION when the newest tag is a
#             major behind, and the tag when it is a major ahead.
#   surfaces  every surface in ci/version-surfaces.txt states VERSION.
#
# They were four scripts copied into seven repositories; three read VERSION,
# one read the CHANGELOG, and each one's comment explained why the others could
# not see what it saw. One gate, so no repository runs three arms and believes
# it asked the question.
#
#   --arms     which arms to run (default: all four). A repository with no CMake
#              build (the macOS host) runs `--arms lockstep`; that is a
#              statement in its profile, never a silent skip here.
#   --min <n>  passed to the floors arm (see there).
#   --section <v>  print that CHANGELOG section on stdout (the release-notes
#              extractor); exits 1 when it is missing or blank.
#   --list     print every floor with the verdict the floors arm would reach.
#
# The tree judged is REPO_ROOT (default $GITHUB_WORKSPACE, then the git
# toplevel of the current directory) -- never this script's location, which on
# a runner is the shared-gates checkout. Every relative path below (VERSION,
# CHANGELOG.md, CMakeLists.txt, ci/version-surfaces.txt) is read there.
# Inputs, as before: CHANGELOG_FILE, VERSION_FILE, SURFACE_LIST, CMAKE,
# LIBRESCRS_FLOOR_MAJOR.
#
# Exit: 0 every arm run agrees - 1 at least one arm found a disagreement
#       2 no arm found a disagreement and at least one could not measure --
#         NOT a pass. (A usage error is 2 as well.)
#
# ============================================================== lockstep ==
# The CHANGELOG and the VERSION file must agree on the version passed in.
#
# Two callers, one body. The cheap lint job passes the version this tree is
# heading for (the first line of VERSION), so the check runs on every push;
# the release job passes the tag's version, so it runs again on the tag. Until
# this existed the extraction awk lived in five copies across the components,
# and one of them had drifted: without escaping the dots, tag 5.0.0 also
# matched a [500.0] heading.
#
# Excluding pre-release tags is a property of the TAG, not of this check, so it
# stays in the workflow that knows what a tag is.
#
# ================================================================ floors ==
# Every first-party `find_package(...)` / `find_dependency(...)` version floor
# in this repository must name the SAME MAJOR as the VERSION file.
#
# Why a property and not a token: the 4.x floors were swept for with
# `git grep 4.2`, and the one that mattered read `4.0`, so it survived the
# sweep and the only executable consumer in the project kept a floor no shipped
# package can satisfy. Counting hits cannot answer "is any floor wrong";
# comparing every floor against VERSION can.
#
# Why VERSION and not `git describe`: `describe` answers with the PREVIOUS
# release for the whole development cycle, so a gate reading it would call the
# tree green while the package the tree ships is a major ahead. VERSION is
# bumped at code freeze and is the only version present in a source tarball.
#
# Equality, not ">=": the Config packages declare COMPATIBILITY
# SameMajorVersion, under which a floor ABOVE the installed major is exactly as
# unsatisfiable as one below it. Measured in both directions.
#
# The major is not the whole floor. A generated SameMajorVersion file rejects a
# request whose lower bound is above the installed version before it ever looks
# at the major, so `5.1...<6.0` against an installed 5.0.0 is refused while its
# major agrees; and it rejects one whose upper bound excludes the installed
# version for the mirror-image reason, so `5.0...<5.1` goes unsatisfiable the
# day VERSION reaches 5.1 without any digit in it changing. On top of that the
# upper bound carries a major rule of its own: an INCLUSIVE top must sit inside
# the installed major, an EXCLUSIVE top may reach the next major exactly and no
# further. Measured against a real install of 5.0.0, not derived from the
# generated file: `5.0...6.0` and `5.0...<7.0` are both refused with "no
# configuration file compatible with requested version range", while
# `5.0...<6.0` and `5.0...5.9` configure. A floor on the package THIS
# repository publishes is therefore compared whole -- BOTH ends of a range, by
# value and by major -- against the whole VERSION. There, and only there, is
# the shipped version known exactly. Floors on every other package keep the
# major-only comparison, because this checkout cannot know another component's
# minor.
#
# The whole-floor comparison needs the package name, and the name is read from
# `project()` in the top-level CMakeLists.txt. When it cannot be read the check
# falls back to the major-only one it was written to replace, which is a
# comparison disappearing quietly -- the shape this gate exists to remove. So
# `--min`, which is the caller stating that this repository is meant to be
# measurable, makes an unreadable name rc=2 instead of a green run with a note.
# Without `--min` the note alone stands, because a checkout with no CMake build
# publishes no package of its own and has nothing to compare whole; that is the
# call a cross-repository check makes on such a repository, and it must not be
# turned into a failure for lacking something it never had.
#
# What that comparison rests on is VERSION being the truth about what this
# repository ships, so it stands down exactly when something says it is not.
# An expectation naming a DIFFERENT major than VERSION says precisely that, and
# for the package it covers the comparison drops back to majors -- announced on
# stderr, because a check that disappears quietly is not a check. An
# expectation naming the SAME major as VERSION contradicts nothing and stands
# nothing down: an override that changes no expectation must not silently
# remove a comparison.
#
# The expected major is this repository's own VERSION, which is the right answer
# only while every component shares a major. That premise is STATED here, not
# proved here: the lockstep arm compares this repository's
# CHANGELOG against this repository's VERSION and has no view of any other
# checkout, and no check in this repository can have one.
#
# The premise stops holding on purpose, not by accident: a major bump reaches
# the components one at a time, and for that whole window a floor naming the NEW
# major is correct while this repository's VERSION still names the old one. So
# the expectation is keyed per PACKAGE and not only per repository --
# LIBRESCRS_FLOOR_MAJOR takes a bare major for everything, or `Package=major`
# pairs, or both:
#
#   LIBRESCRS_FLOOR_MAJOR=6                       every first-party floor is 6
#   LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=6"     that package is 6, the rest
#                                                 keep the major in VERSION
#   LIBRESCRS_FLOOR_MAJOR="LibreMiddleware=6 4"   ... and 4 for the rest
#
# Both spellings are expectations in the sense above: whichever one ends up
# covering this repository's own package decides whether that package's floors
# are still comparable against the whole VERSION.
#
# Without that the only way through the window is to stop running the gate,
# which is not a transfer of the check to anybody.
#
# Exemptions, each for a reason and no others:
#   CHANGELOG.md   a release note naming the floor a past release carried is a
#                  correct historical record, not a live floor.
#   thirdparty/    vendored code, not ours to version.
# (This gate and its self-test carry wrong floors on purpose; they no longer live
# in the tree they judge, so they need no exemption.)
#
# ================================================================= stamp ==
# The version this tree STAMPS -- what `project()` ends up with, and with it the
# Config package, the SONAME, the packaging metadata and every banner -- must
# name the same major as the VERSION file, even while the newest reachable
# release tag is still a major behind.
#
# Why this is not covered by anything else: the floors arm reads
# VERSION and the sources, so it is green whatever the version derivation does;
# configuring with an EMPTY GIT_EXECUTABLE measures the tarball path, which is
# the one input under which a tag cannot win at all; and a test that asserts
# the stamp is self-consistent (triple is a prefix of the full string, not the
# 0.0.1 fallback) is satisfied by the wrong major exactly as by the right one.
# The defect this measures shipped in a release-shaped tree with
# all three of those green: VERSION, the changelog and the package metadata said
# 5.0.0 while project(), the About window and the bundle keys said 4.2.0.
#
# How it is measured, and why a stub rather than the checkout's own tags: the
# real top-level CMakeLists is configured with GIT_EXECUTABLE pointed at a
# script that answers `describe` with a tag chosen by this gate, and with
# CMAKE_PROJECT_INCLUDE pointed at a probe that records PROJECT_VERSION and
# stops the configure before the first find_package(). So the answer does not
# depend on which tags the CI checkout happened to fetch -- a shallow clone with
# no tags would otherwise make the interesting case unreachable and the gate
# vacuously green -- and no tag is ever created anywhere.
#
# Two cases, because one of them alone is passed by a module that is simply
# wrong in the other direction:
#   behind  tag one major BELOW VERSION  -> the stamp must be VERSION's major
#   ahead   tag one major ABOVE VERSION  -> the stamp must be the TAG's major
# A module that ignored git would pass the first and fail the second; one that
# lets the tag decide unconditionally does the reverse.
#
# ============================================================== surfaces ==
# Every surface that states this repo's version must state the one in VERSION.
#
# The lockstep arm already proves the CHANGELOG and VERSION agree, but
# both of its sides read the same file, so it cannot prove the BUILD agrees.
# It did not: LibreKDE's VERSION, CHANGELOG, PKGBUILD, debian/changelog and rpm
# spec all said 5.0.0 while project() stamped 0.1.0, and the About window, the
# --version output and the plasmoid's applet information all showed 0.1.0. A
# package labelled 5.0.0 installed a binary that said it was 0.1.0.
#
# The surfaces are listed in the consumer's ci/version-surfaces.txt, so one gate
# serves every repository.
#
# Three kinds read packaging rather than the build: the Debian changelog and
# the RPM spec, which label the packages, and a shell helper the packaging
# scripts source to name the artefacts they build. Nothing else compared any
# of them with VERSION.
#
# Two surface kinds accept a configure_file() template in place of a literal,
# and they differ in how strict that acceptance is. plasma-metadata is listed
# as the plain metadata.json; when that file is absent the script reads
# metadata.json.in instead and requires it to take "Version" from
# @PROJECT_VERSION@, with no further condition -- the plasmoid package is
# installed from the configured copy, so the template is the source of truth
# for that kind. plist-short-version is listed as the .plist.in itself, and
# is accepted as a template only when the list also carries a cmake-project
# row: a plist has no installer step that vouches for a configured copy
# standing in for it, so a template with nothing else in the list measuring
# the stamped number would state no number at all. The two shapes are
# deliberately different in strictness for that reason, and a plain
# (non-.in) plist holding the placeholder is still a mismatch, not a
# template.
set -u

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "check-version: needs bash >= 4 -- cannot judge" >&2; exit 2; }

usage() {
    echo "usage: check-version.sh [--version <v>] [--arms lockstep,floors,stamp,surfaces] [--min <n>] [--verbose]" >&2
    echo "       check-version.sh --section <v>" >&2
    echo "       check-version.sh --list" >&2
    exit 2
}

ARMS=lockstep,floors,stamp,surfaces
VER_ARG=""
SECTION_VER=""
TOP=check
MIN=0
VERBOSE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) [ "$#" -ge 2 ] || usage; VER_ARG=$2; shift ;;
        --arms)    [ "$#" -ge 2 ] || usage; ARMS=$2; shift ;;
        --min)     [ "$#" -ge 2 ] || usage; MIN=$2; shift ;;
        --section) [ "$#" -ge 2 ] || usage; SECTION_VER=$2; TOP=section; shift ;;
        --list)    TOP=list ;;
        --verbose) VERBOSE=1 ;;
        *) usage ;;
    esac
    shift
done

root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
if [ -z "$root" ] || ! cd -- "$root" 2>/dev/null; then
    echo "check-version: no consumer tree '${root:-<unset>}' (set REPO_ROOT) -- cannot judge" >&2
    exit 2
fi

# ------------------------------------------------------------ lockstep arm --
# arm_lockstep <assert|section> <version>; run in a subshell, so `exit` ends
# the arm and not the gate.
arm_lockstep() {
MODE=$1
VER=${2#v}
[ -n "$VER" ] || { echo "check-version lockstep: no version to check (VERSION empty and no --version)" >&2; exit 2; }
CHANGELOG=${CHANGELOG_FILE:-CHANGELOG.md}
VERSION_FILE=${VERSION_FILE:-VERSION}

FAIL=0

# Extract with the SAME awk the release-notes step uses, then require the
# section to hold a non-whitespace character. Testing only for the header let a
# header with nothing under it pass, and the release then shipped precisely the
# generic auto-notes the error text warns about. Matching with a second,
# near-miss pattern also made the two steps disagree: `^## .*(\[|[[:space:]])`
# spends the space in its own `## ` prefix, so a bracket-less `## 5.0.0` header
# was called missing here while the extractor read it correctly.
#
# A missing CHANGELOG is the no-section case, said out loud: an awk over an
# absent file would otherwise die before this branch could report anything.
extract() {  # extract <version>: that version's CHANGELOG section, or nothing
    [ -f "$CHANGELOG" ] || return 0
    awk -v ver="$1" \
        'BEGIN { gsub(/\./, "\\.", ver) }
         /^## / { if ($0 ~ ("(\\[|[[:space:]])" ver "(\\]|[[:space:]]|$)")) {f=1; next} else if (f) exit } f' \
        "$CHANGELOG"
}
SECTION="$(extract "$VER")"
# --section is the release job's notes extractor. It is the SAME awk above,
# reached through the same file, because five hand-copied extractors are what
# let one of them drift: without the dot escaping, tag 5.0.0 also matched a
# [500.0] heading. A section that exists but holds only whitespace is a miss —
# `gh release create --notes-file` accepts a blank file and publishes a release
# with no body at all — so the caller can branch on the exit code.
# A pre-release tag (5.0.0-rc1) falls back to the section of its base version
# when it has none of its own, so a rehearsal publishes exactly the notes the
# final tag will. Only here, and only when the exact version has no non-empty
# section: a repository that keeps a pre-release section still gets that one,
# and the agreement check below is untouched.
if [ "$MODE" = section ] && ! printf '%s' "$SECTION" | grep -q '[^[:space:]]' \
        && [ "${VER%%-*}" != "$VER" ]; then
    SECTION="$(extract "${VER%%-*}")"
fi
if [ "$MODE" = section ]; then
    printf '%s\n' "$SECTION"
    printf '%s' "$SECTION" | grep -q '[^[:space:]]'
    exit $?
fi

if ! printf '%s' "$SECTION" | grep -q '[^[:space:]]'; then
    echo "::error::CHANGELOG.md has no section for $VER, or the section is empty — the release would ship generic auto-notes. Rename the [Unreleased] header before tagging."
    FAIL=1
fi

FILE_VER="$(head -n1 "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
FILE_VER=${FILE_VER#v}
if [ "$FILE_VER" != "$VER" ]; then
    echo "::error::VERSION file holds '$FILE_VER' but the tag is '$VER' — no-git source drops would stamp the wrong version. Bump VERSION with the tag."
    FAIL=1
fi

[ "$FAIL" -eq 0 ] && echo "  -> changelog and VERSION agree on $VER"
exit "$FAIL"
}

# -------------------------------------------------------------- floors arm --
# arm_floors <check|list>
arm_floors() {
MODE=$1
VERSION_FILE=${VERSION_FILE:-VERSION}
WANT=""
MAP=""
for tok in $(printf '%s' "${LIBRESCRS_FLOOR_MAJOR:-}" | tr ',' ' '); do
    case "$tok" in
        *=*)
            pkg=${tok%%=*}; maj=${tok#*=}
            case "$pkg" in ''|*[!A-Za-z0-9_]*) maj="" ;; esac
            case "$maj" in ''|*[!0-9]*)
                echo "::error::LIBRESCRS_FLOOR_MAJOR: \"$tok\" is not <Package>=<major>" >&2
                exit 2 ;;
            esac
            MAP="$MAP $pkg=$maj" ;;
        *[!0-9]*)
            echo "::error::LIBRESCRS_FLOOR_MAJOR: \"$tok\" is neither a major nor <Package>=<major>" >&2
            exit 2 ;;
        *) WANT=$tok ;;
    esac
done
FILE_VER="$(head -n1 "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
FILE_VER=${FILE_VER#v}
FILE_MAJ="$(printf '%s' "$FILE_VER" | sed -n 's/^\([0-9][0-9]*\).*$/\1/p')"
ENV_WANT=0
if [ -n "$WANT" ]; then
    ENV_WANT=1
else
    WANT=$FILE_MAJ
fi
if [ -z "$WANT" ]; then
    echo "::error::no major version in $VERSION_FILE -- floors NOT measured" >&2
    exit 2
fi

# The whole-floor comparison needs a package name AND a version it can trust.
SELF_PKG="$(sed -n 's/^[[:space:]]*project([[:space:]]*\([A-Za-z][A-Za-z0-9_]*\).*$/\1/p' \
            CMakeLists.txt 2>/dev/null | head -n1)"
SELF_VER=""
SELF_UNREADABLE=0
if [ -z "$SELF_PKG" ]; then
    echo "note: no project() name in CMakeLists.txt -- floors are compared by major only" >&2
    SELF_UNREADABLE=1
elif [ -z "$FILE_MAJ" ]; then
    echo "note: no version in $VERSION_FILE -- floors are compared by major only" >&2
    SELF_UNREADABLE=1
else
    OWN_WANT=$WANT
    for pair in $MAP; do
        case "$pair" in "$SELF_PKG"=*) OWN_WANT=${pair#*=} ;; esac
    done
    if [ "$OWN_WANT" = "$FILE_MAJ" ]; then
        SELF_VER=$FILE_VER
    else
        echo "note: floors on $SELF_PKG are expected at major $OWN_WANT, not the $FILE_MAJ in" \
             "$VERSION_FILE -- they are compared by major only" >&2
    fi
fi
case "$MIN" in ''|*[!0-9]*|0) MIN_POS=0 ;; *) MIN_POS=1 ;; esac
if [ "$SELF_UNREADABLE" -eq 1 ] && [ "$MIN_POS" -eq 1 ]; then
    echo "::error::--min was given, so this repository is meant to be measurable, but the" >&2
    echo "         whole-floor comparison could not be set up -- floors only PARTLY measured" >&2
    exit 2
fi

HITS="$(git grep -nIE 'find_(package|dependency)\([ 	]*Libre[A-Za-z]+[ 	]+[0-9]' -- . \
        ':!thirdparty' ':!CHANGELOG.md' 2>/dev/null)"
g=$?
if [ "$g" -ge 2 ]; then
    echo "::error::git grep exited $g -- version floors NOT measured (is this a git checkout?)" >&2
    exit 2
fi

printf '%s\n' "$HITS" | awk -v want="$WANT" -v map="$MAP" -v mode="$MODE" -v min="$MIN" -v vf="$VERSION_FILE" \
                              -v self_pkg="$SELF_PKG" -v self_ver="$SELF_VER" \
                              -v envwant="$ENV_WANT" '
function above(a, b,   x, y, i, n, m) {   # 1 when version a sorts above version b
  n = split(a, x, "."); m = split(b, y, ".")
  if (n > m) m = n
  for (i = 1; i <= m; i++) {
    if ((x[i] + 0) > (y[i] + 0)) return 1
    if ((x[i] + 0) < (y[i] + 0)) return 0
  }
  return 0
}
BEGIN {
  n = split(map, pairs, /[ \t]+/)
  for (i = 1; i <= n; i++) {
    if (pairs[i] == "") continue
    eq = index(pairs[i], "=")
    want_of[substr(pairs[i], 1, eq - 1)] = substr(pairs[i], eq + 1)
    keyed++
  }
  if (self_ver != "") { split(self_ver, sv, "."); self_maj = sv[1] + 0; self_next = self_maj + 1 }
}
$0 == "" { next }
{
  s = $0
  while (match(s, /find_(package|dependency)\([ \t]*Libre[A-Za-z]+[ \t]+[0-9][^ \t)]*/)) {
    tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    pkg = tok; sub(/^find_(package|dependency)\([ \t]*/, "", pkg); sub(/[ \t].*$/, "", pkg)
    ver = tok; sub(/^.*[ \t]/, "", ver)
    maj = ver; sub(/[^0-9].*$/, "", maj)
    low = ver; sub(/\.\.\..*$/, "", low)   # a range floors at its lower bound
    hi = ""; hi_excl = 0                   # ... and, when it is a range, ceilings at the other
    if (ver ~ /\.\.\./) {
      hi = ver; sub(/^.*\.\.\./, "", hi)
      if (substr(hi, 1, 1) == "<") { hi_excl = 1; hi = substr(hi, 2) }
    }
    hi_maj = hi; sub(/[^0-9].*$/, "", hi_maj)
    seen++
    xmaj = (pkg in want_of) ? want_of[pkg] : want
    src = ((pkg in want_of) || envwant + 0) ? "LIBRESCRS_FLOOR_MAJOR" : vf
    mine = (self_ver != "" && pkg == self_pkg)
    low_bad = (mine && above(low, self_ver))
    # Two independent ways for the top of a range to exclude what we ship: by
    # value (it sits at or below the installed version) and by major (it reaches
    # past the installed major line, which SameMajorVersion refuses whatever the
    # digits say).
    hi_val_bad = (mine && hi != "" && \
                  ((hi_excl && !above(hi, self_ver)) || (!hi_excl && above(self_ver, hi))))
    hi_maj_bad = (mine && hi != "" && \
                  ((hi_excl && above(hi, self_next "")) || (!hi_excl && (hi_maj + 0) != self_maj)))
    if (mode == "list") {
      mark = (maj != xmaj) ? "MAJOR-MISMATCH" : \
             ((low_bad || hi_val_bad || hi_maj_bad) ? "UNSATISFIABLE" : "")
      printf "  %-16s floor %-13s major %-3s expected %-3s %-14s %s\n", pkg, ver, maj, xmaj, mark, $0
    }
    else if (maj != xmaj) {
      printf "::error::%s\n", $0
      printf "          floor on %s is major %s; %s says major %s\n", pkg, maj, src, xmaj
      bad++
    }
    else if (low_bad) {
      printf "::error::%s\n", $0
      printf "          floor on %s starts at %s; this repository ships %s, so the package\n", pkg, low, self_ver
      printf "          it installs cannot satisfy it\n"
      bad++
    }
    else if (hi_val_bad) {
      printf "::error::%s\n", $0
      printf "          range on %s ends at %s%s, which excludes the %s this repository\n", pkg, (hi_excl ? "<" : ""), hi, self_ver
      printf "          ships, so the package it installs cannot satisfy it\n"
      bad++
    }
    else if (hi_maj_bad) {
      printf "::error::%s\n", $0
      printf "          range on %s ends at %s%s, outside the major %s line this repository\n", pkg, (hi_excl ? "<" : ""), hi, self_maj
      printf "          ships; an inclusive top has to stay inside that major and an exclusive\n"
      printf "          one may reach %s exactly, no further\n", self_next
      bad++
    }
  }
}
END {
  if (mode == "list") {
    printf "  %d floor(s) examined\n", seen+0
    if (self_ver != "")
      printf "  own package %s ships %s -- both ends of its floors are compared by value and\n", self_pkg, self_ver
      printf "  by major; every other package by major only\n"

    exit 0
  }
  if (seen+0 < min+0) {
    printf "::error::only %d first-party floor(s) found, --min %d -- the scan matched nothing it was meant to measure\n", seen+0, min+0
    exit 1
  }
  if (bad+0) { printf "%d floor(s) disagree with the expected version\n", bad; exit 1 }
  if (keyed+0) { printf "  -> %d first-party version floor(s), each naming its expected major (default %s)\n", seen+0, want; exit 0 }
  printf "  -> %d first-party version floor(s), all major %s\n", seen+0, want
  exit 0
}'
}

# --------------------------------------------------------------- stamp arm --
arm_stamp() {
VERSION_FILE=${VERSION_FILE:-VERSION}
FILE_VER="$(head -n1 "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
FILE_VER=${FILE_VER#v}
WANT="$(printf '%s' "$FILE_VER" | sed -n 's/^\([0-9][0-9]*\).*$/\1/p')"
if [ -z "$WANT" ]; then
    echo "::error::no major version in $VERSION_FILE -- the stamped version was NOT measured" >&2
    exit 2
fi

[ -f CMakeLists.txt ] || {
    echo "::error::no CMakeLists.txt here -- the stamped version was NOT measured" >&2; exit 2; }
command -v cmake >/dev/null 2>&1 || {
    echo "::error::cmake not found -- the stamped version was NOT measured" >&2; exit 2; }
REAL_GIT="$(command -v git 2>/dev/null)"
[ -n "$REAL_GIT" ] || {
    echo "::error::git not found -- the stamped version was NOT measured" >&2; exit 2; }

SRC="$(pwd)"
TMP="$(mktemp -d)" || { echo "::error::mktemp failed -- the stamped version was NOT measured" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/probe.cmake" <<'PROBE'
file(WRITE "$ENV{LIBRESCRS_STAMP_OUT}" "${PROJECT_VERSION}")
message(FATAL_ERROR "version-stamp probe: stopping before the first find_package()")
PROBE

# The stub answers only `describe`; everything else the module asks (which
# repository is this, where is the git dir) must keep telling the truth, or the
# module under test takes a path no real build ever takes.
stub() {
    cat > "$TMP/git" <<STUB
#!/usr/bin/env sh
if [ "\${1:-}" = "describe" ]; then printf '%s\n' '$1'; exit 0; fi
exec "$REAL_GIT" "\$@"
STUB
    chmod 755 "$TMP/git"
}

rc=0
run_case() {
    _label=$1; _tag=$2; _expect=$3
    stub "$_tag"
    rm -rf "$TMP/b" "$TMP/stamp"
    LIBRESCRS_STAMP_OUT="$TMP/stamp" cmake -S "$SRC" -B "$TMP/b" \
        -DGIT_EXECUTABLE="$TMP/git" -DCMAKE_PROJECT_INCLUDE="$TMP/probe.cmake" \
        > "$TMP/log" 2>&1
    _got="$(cat "$TMP/stamp" 2>/dev/null)"
    if [ -z "$_got" ]; then
        echo "::error::configure never reached project() with the probe attached -- the stamped version was NOT measured" >&2
        tail -n 15 "$TMP/log" >&2
        exit 2
    fi
    _maj="$(printf '%s' "$_got" | sed -n 's/^\([0-9][0-9]*\).*$/\1/p')"
    if [ "$VERBOSE" = 1 ]; then
        printf '  %-7s tag %-10s -> stamped %-12s (expected major %s)\n' "$_label" "$_tag" "$_got" "$_expect"
    fi
    if [ "$_maj" != "$_expect" ]; then
        printf '::error::%s: with the nearest release tag at %s and %s at %s, the tree stamps %s\n' \
               "$_label" "$_tag" "$VERSION_FILE" "$FILE_VER" "$_got" >&2
        printf '          project() must carry major %s here, not %s\n' "$_expect" "${_maj:-<none>}" >&2
        rc=1
    fi
}

BEHIND=$((WANT - 1))
AHEAD=$((WANT + 1))
if [ "$BEHIND" -lt 0 ]; then
    echo "::error::$VERSION_FILE names major $WANT -- no major below it to measure against" >&2
    exit 2
fi

run_case behind "${BEHIND}.0.0" "$WANT"
run_case ahead  "${AHEAD}.0.0"  "$AHEAD"

if [ "$rc" = 0 ]; then
    echo "  -> the tree stamps major $WANT with a stale tag, and the tag's major when the tag is ahead"
fi
exit "$rc"
}

# ------------------------------------------------------------ surfaces arm --
arm_surfaces() {
VERSION_FILE=${VERSION_FILE:-VERSION}
SURFACE_LIST=${SURFACE_LIST:-ci/version-surfaces.txt}
CMAKE=${CMAKE:-cmake}

undecidable() {   # rc=2 is "I could not judge" -- never "pass"
    echo "::error::check-version surfaces: $1"
    exit 2
}

[ -f "$VERSION_FILE" ] || undecidable "no $VERSION_FILE to check against"
WANT="$(head -n1 "$VERSION_FILE" | tr -d '[:space:]')"
WANT=${WANT#v}
[ -n "$WANT" ] || undecidable "$VERSION_FILE is empty"
[ -f "$SURFACE_LIST" ] || undecidable "no $SURFACE_LIST -- nothing says which surfaces to check"

WORK="$(mktemp -d)" || undecidable "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
CHECKED=0
TEMPLATED=0

report() {   # report <surface> <found>
    if [ "$2" = "$WANT" ]; then
        echo "  -> $1 states $WANT"
    else
        echo "::error::$1 states '$2' but $VERSION_FILE says '$WANT' -- a package labelled $WANT would ship something that calls itself $2."
        FAIL=1
    fi
}

# --- kind: cmake-project ----------------------------------------------------
# Measures the number project() actually stamps, by configuring the REAL
# CMakeLists.txt with CMAKE_PROJECT_INCLUDE -- a file CMake evaluates the
# moment project() returns. The probe writes the version out and aborts, so no
# find_package() runs and this needs none of the project's dependencies.
# Reading the number out of a hand-written mock would measure the mock.
#
# GIT_EXECUTABLE is defined-but-empty on purpose: GitVersion.cmake then takes
# the VERSION-file path, which is the path a release tarball takes and the one
# packagers build. With git left on, `git describe` wins, and between a release
# and the next code freeze the newest tag legitimately differs from VERSION --
# the check would go red on a tree with nothing wrong with it.
check_cmake_project() {
    dir=$1
    command -v "$CMAKE" >/dev/null 2>&1 || undecidable "no cmake on PATH (set CMAKE=) -- cannot measure what project() stamps"
    cat > "$WORK/probe.cmake" <<'PROBE'
file(WRITE "$ENV{VERSION_SURFACE_OUT}" "${PROJECT_NAME} ${PROJECT_VERSION}\n")
message(FATAL_ERROR "check-version-surfaces: probe done, stopping before find_package()")
PROBE
    VERSION_SURFACE_OUT="$WORK/stamp"
    export VERSION_SURFACE_OUT
    rm -rf "$WORK/build" "$VERSION_SURFACE_OUT"
    "$CMAKE" -S "$dir" -B "$WORK/build" -DGIT_EXECUTABLE= \
        -DCMAKE_PROJECT_INCLUDE="$WORK/probe.cmake" > "$WORK/configure.log" 2>&1
    if [ ! -s "$VERSION_SURFACE_OUT" ]; then
        sed 's/^/    /' "$WORK/configure.log" >&2
        undecidable "the configure of '$dir' died before project() reported anything (log above)"
    fi
    name="$(cut -d' ' -f1 "$VERSION_SURFACE_OUT")"
    got="$(cut -d' ' -f2 "$VERSION_SURFACE_OUT")"
    # An empty stamp is a failure to measure, not a mismatch: a CMakeLists.txt
    # with no project() call still fires this hook, because CMake supplies an
    # implicit project(Project) carrying no version. Calling that a mismatch
    # would blame the tree for this check's own blind spot.
    [ -n "$got" ] || undecidable "project($name) in '$dir' carries no VERSION to measure"
    report "project($name) in $dir" "$got"
}

# --- kind: plasma-metadata --------------------------------------------------
# KPlugin.Version in a Plasma package metadata.json. The package directory is
# installed verbatim by plasma_install_package(), so whatever stands here is
# what Plasma shows in the widget's information.
#
# Two shapes are accepted: a literal, which must equal VERSION; or a
# metadata.json.in template carrying @PROJECT_VERSION@ and no literal beside
# it, for a tree that has moved to configure_file(). A literal @PROJECT_VERSION@
# inside an installed metadata.json is neither -- that is a configure_file()
# that never ran, and Plasma would show the placeholder itself.
check_plasma_metadata() {
    f=$1
    if [ -f "$f" ]; then
        got="$(sed -n 's/^[[:space:]]*"Version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n1)"
        if [ -z "$got" ]; then
            echo "::error::$f has no \"Version\" key -- Plasma would show no version for the applet."
            FAIL=1
        elif [ "$got" = '@PROJECT_VERSION@' ]; then
            echo "::error::$f still holds the literal @PROJECT_VERSION@ -- it is installed verbatim, so configure_file() must write it into the build dir and plasma_install_package() must point there."
            FAIL=1
        else
            report "$f (KPlugin.Version)" "$got"
        fi
    elif [ -f "$f.in" ]; then
        if grep -q '"Version"[[:space:]]*:[[:space:]]*"@PROJECT_VERSION@"' "$f.in"; then
            TEMPLATED=$((TEMPLATED + 1))
            echo "  -> $f.in takes Version from @PROJECT_VERSION@"
        else
            echo "::error::$f.in does not take \"Version\" from @PROJECT_VERSION@."
            FAIL=1
        fi
    else
        undecidable "neither $f nor $f.in exists"
    fi
}

# --- kind: plist-short-version ----------------------------------------------
# CFBundleShortVersionString in an XML plist -- the embedded __info_plist of a
# bare Mach-O, or a bundle's Info.plist. This is the number Finder, `mdls`,
# About windows and anything reading Bundle.main.infoDictionary report.
#
# A listed path ending in .in is a configure_file() template, and the same two
# shapes apply as for the plugin metadata: @PROJECT_VERSION@ is what a tree
# that has stopped hand-typing the number looks like, while a literal inside a
# template is still a hand-typed number and is still compared against VERSION.
# The difference from the metadata kind is the extra condition: a template
# states no number of its own, so it is accepted only when the list also names
# a cmake-project surface -- that one measures what the build really stamps,
# which is the number configure_file() fills in here. With no such surface the
# whole list could become templates and the gate would have nothing left to
# compare, which is a vacuum, not a pass.
check_plist_short_version() {
    f=$1
    [ -f "$f" ] || undecidable "$f does not exist"
    is_template=0
    case "$f" in *.in) is_template=1 ;; esac
    got="$(awk '/<key>CFBundleShortVersionString<\/key>/ {
                    getline
                    if (match($0, /<string>[^<]*<\/string>/)) {
                        print substr($0, RSTART + 8, RLENGTH - 17); exit
                    }
                }' "$f")"
    if [ -z "$got" ]; then
        echo "::error::$f has no CFBundleShortVersionString."
        FAIL=1
    elif [ "$is_template" -eq 1 ] && [ "$got" = '@PROJECT_VERSION@' ]; then
        [ "$HAS_CMAKE_PROJECT" -eq 1 ] || undecidable "$f takes CFBundleShortVersionString from @PROJECT_VERSION@, but $SURFACE_LIST names no cmake-project surface -- nothing measures the number the build would fill in here."
        TEMPLATED=$((TEMPLATED + 1))
        echo "  -> $f takes CFBundleShortVersionString from @PROJECT_VERSION@"
    else
        report "$f (CFBundleShortVersionString)" "$got"
    fi
}

# --- kind: yaml-short-version -----------------------------------------------
# CFBundleShortVersionString in an xcodegen project spec. This one is upstream
# of the generated Info.plist: editing the plist alone is undone by the next
# `xcodegen generate`.
check_yaml_short_version() {
    f=$1
    [ -f "$f" ] || undecidable "$f does not exist"
    got="$(sed -n 's/^[[:space:]]*CFBundleShortVersionString:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$f" | head -n1)"
    if [ -z "$got" ]; then
        echo "::error::$f has no CFBundleShortVersionString."
        FAIL=1
    else
        report "$f (CFBundleShortVersionString)" "$got"
    fi
}

# --- kind: debian-changelog -------------------------------------------------
# The first entry of a Debian changelog names the version dpkg stamps on every
# package built from the tree. Only the upstream part is compared: a leading
# epoch ("1:") and the trailing Debian revision ("-1") belong to the packaging,
# not to the release.
check_debian_changelog() {
    f=$1
    [ -f "$f" ] || undecidable "$f does not exist"
    got="$(head -n1 "$f" | sed -n 's/^[^ ]* (\([^)]*\)).*/\1/p')"
    if [ -z "$got" ]; then
        echo "::error::$f does not open with a '<source> (<version>) ...' entry."
        FAIL=1
        return
    fi
    got=${got#*:}
    got=${got%-*}
    report "$f (Debian version)" "$got"
    # The file is generated, never edited by hand: say which generator.
    [ "$got" = "$WANT" ] \
        || echo "::error::regenerate $f with ci/scripts/changelog-to-debian.sh <source-package> $f"
}

# --- kind: rpm-spec-version --------------------------------------------------
# The spec's Version: tag, which rpmbuild stamps on the package name.
check_rpm_spec_version() {
    f=$1
    [ -f "$f" ] || undecidable "$f does not exist"
    got="$(sed -n 's/^Version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f" | head -n1)"
    if [ -z "$got" ]; then
        echo "::error::$f has no Version: tag."
        FAIL=1
    else
        report "$f (Version:)" "$got"
    fi
}

# --- kind: shell-version-helper ----------------------------------------------
# A helper other scripts source to name the artefacts they build: it defines
# project_version <root>. It is asked with the ABSOLUTE, physical root, as its
# production callers ask it. That is not style: a helper that consults git only
# when its argument equals git's toplevel never matches a relative ".", falls
# through to the VERSION file, and prints the right number for the wrong
# reason -- the check would then be measuring the guard, not the surface.
check_shell_version_helper() {
    f=$1
    [ -f "$f" ] || undecidable "$f does not exist"
    command -v bash >/dev/null 2>&1 || undecidable "no bash on PATH -- cannot run $f"
    root="$(cd . && pwd -P)"
    got="$(bash -c '. "$1" && project_version "$2"' _ "$root/$f" "$root" 2>"$WORK/helper.err")" \
        || { sed 's/^/    /' "$WORK/helper.err" >&2; undecidable "$f could not be sourced, or project_version failed"; }
    [ -n "$got" ] || undecidable "$f: project_version printed nothing"
    report "$f (project_version)" "$got"
}

# Pre-scan for the surface that measures what the build stamps. A template is
# only judgeable through that one, and the list is read in file order, so a
# cmake-project row standing AFTER the rows it vouches for would otherwise be
# invisible to them -- the gate would then depend on how the list is sorted.
HAS_CMAKE_PROJECT=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    [ "${line%%[ 	]*}" = cmake-project ] && HAS_CMAKE_PROJECT=1
done < "$SURFACE_LIST"

while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    kind=${line%%[ 	]*}
    path=${line#"$kind"}
    path=$(printf '%s' "$path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$path" ] || undecidable "$SURFACE_LIST: '$line' names a kind but no path"
    CHECKED=$((CHECKED + 1))
    case "$kind" in
        cmake-project)       check_cmake_project "$path" ;;
        plasma-metadata)     check_plasma_metadata "$path" ;;
        plist-short-version) check_plist_short_version "$path" ;;
        yaml-short-version)  check_yaml_short_version "$path" ;;
        debian-changelog)    check_debian_changelog "$path" ;;
        rpm-spec-version)    check_rpm_spec_version "$path" ;;
        shell-version-helper) check_shell_version_helper "$path" ;;
        *) undecidable "$SURFACE_LIST: unknown surface kind '$kind'" ;;
    esac
done < "$SURFACE_LIST"

# An empty list is the vacuum case: every surface agreed because none was
# named. A gate that cannot fail is not a gate.
[ "$CHECKED" -gt 0 ] || undecidable "$SURFACE_LIST names no surfaces"

if [ "$FAIL" -eq 0 ]; then
    if [ "$TEMPLATED" -gt 0 ]; then
        echo "  -> all $CHECKED version surface(s) agree with VERSION ($TEMPLATED read the number from a configure_file template)"
    else
        echo "  -> all $CHECKED version surface(s) state $WANT"
    fi
fi
exit "$FAIL"
}

# -------------------------------------------------------------------- main --
case "$TOP" in
    section) ( arm_lockstep section "$SECTION_VER" ); exit $? ;;
    list)    ( arm_floors list ); exit $? ;;
esac

VER="$VER_ARG"
[ -n "$VER" ] || VER="$(head -n1 "${VERSION_FILE:-VERSION}" 2>/dev/null | tr -d '[:space:]')"

seen=","
IFS=, read -r -a want_arms <<< "$ARMS"
[ "${#want_arms[@]}" -gt 0 ] || { echo "check-version: no arm named -- nothing to measure" >&2; exit 2; }
for arm in "${want_arms[@]}"; do
    case "$arm" in
        lockstep|floors|stamp|surfaces) ;;
        *) echo "check-version: unknown arm '$arm' -- cannot judge" >&2; exit 2 ;;
    esac
    case "$seen" in *",$arm,"*) echo "check-version: arm '$arm' named twice -- cannot judge" >&2; exit 2 ;; esac
    seen="$seen$arm,"
done

worst=0   # a disagreement (1) outranks "could not measure" (2) outranks agreement
ran=0
for arm in lockstep floors stamp surfaces; do
    case "$seen" in *",$arm,"*) ;; *) continue ;; esac
    echo "== check-version: $arm"
    case "$arm" in
        lockstep) ( arm_lockstep assert "$VER" ) ;;
        floors)   ( arm_floors check ) ;;
        stamp)    ( arm_stamp ) ;;
        surfaces) ( arm_surfaces ) ;;
    esac
    rc=$?
    ran=$((ran + 1))
    echo "== check-version: $arm rc=$rc"
    case "$rc" in
        0) ;;
        1) worst=1 ;;
        *) [ "$worst" = 1 ] || worst=2 ;;
    esac
done
echo "check-version: $ran arm(s) run, verdict rc=$worst"
exit "$worst"
