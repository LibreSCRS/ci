#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC1007,SC2010,SC2012,SC2015,SC2016,SC2028,SC2181  # fixture text is literal on purpose; A && B || C report lines
# Selftest for check-release-artifacts.sh, all three arms.
#
# Part one, the needs arm. Thirteen shapes, each one a way the
# check could be wrong rather than merely absent: seven the check must fail or
# pass on its own terms; two -- case_10 and case_11 -- that a direct-needs
# reading gets wrong in the other direction, by failing a workflow that is
# correct or by not terminating at all; and two -- case_12 and case_13 -- that
# a reading per JOB rather than per ARTEFACT gets wrong, which is how a
# consumer needing one producer went on passing after a second producer was
# dropped from its needs.
#
# Part two, the names and producer arms: eleven fixtures, written here rather
# than copied from a repository, so the cases do not change meaning when a
# workflow does. The producer cases need a repository around the workflow
# directory: the arm asks whether the consumer's make-source-tarball.sh is both
# run and published by some job. The commented case is there because naming a
# script in a `#` comment is the cheapest way to turn a textual check green, and
# the unpublished case because a check that only asked whether some step names
# the maker stayed green while a job built the tarball and threw it away.
#
# Fixtures live under /var/tmp -- never /tmp, which is RAM on the maintainer
# machines.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
subject="$here/check-release-artifacts.sh"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/var/tmp}/check-release-artifacts-selftest.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
fails=0
cases=0
red=0

run() {  # run <name> <expected-rc> <dir>
    local name=$1 want=$2 dir=$3
    cases=$((cases + 1))
    # red-proved: the case in which the gate returned non-zero on a perturbed input.
    if [ "$want" != 0 ]; then red=$((red + 1)); fi
    REPO_ROOT="$dir" bash "$subject" "$dir" > "$work/out" 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-56s rc=%s  %s\n' "$name" "$got" "$(grep -m1 '^artifact-consumers=' "$work/out" || true)"
    else
        printf '  FAIL  %-56s rc=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$work/out"
        fails=$((fails + 1))
    fi
}

# case_1 -- a consumer with no producer anywhere in the workflow. This is the
# shape that shipped: release.yml downloaded from a run nobody uploaded to.
d=$work/case_1; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_1 consumer with no producer" 1 "$d"

# case_2 -- the fixed shape: the job it needs uploads.
d=$work/case_2; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
  release:
    needs: package
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_2 producer named in needs" 0 "$d"

# case_3 -- a producer in the same file that the consumer does NOT need. It may
# still be running when the download happens, so it is not a producer for this
# purpose. A grep for upload-artifact anywhere in the file passes this.
d=$work/case_3; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_3 producer not upstream of the consumer" 1 "$d"

# case_4 -- the word appears, the action does not. A comment or a step name
# must never stand in for a step that runs.
d=$work/case_4; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      # actions/upload-artifact@v4 was here once
      - name: upload-artifact
        run: true
  release:
    needs: package
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_4 the word, not the action" 1 "$d"

# case_5 -- needs as a block list.
d=$work/case_5; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: true
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
  release:
    needs:
      - test
      - package
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_5 needs as a block list" 0 "$d"

# case_6 -- needs as a flow list, which is what this repository writes.
d=$work/case_6; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: true
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
  release:
    needs: [test, package]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_6 needs as a flow list" 0 "$d"

# case_7 -- a consumer with no needs at all: nothing orders the producer.
d=$work/case_7; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_7 consumer with no needs" 1 "$d"

# case_8 -- a directory in which no workflow downloads anything measured
# nothing. A census of 0/0/0 is how every workflow without a consumer looks,
# and also how one whose consumer this parser cannot read would look, so it is
# "cannot judge", not a pass. A repository with nothing to download says so in
# its gate-wiring exceptions instead of running this.
d=$work/case_8; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
Y
run "case_8 no consumer anywhere is unmeasured" 2 "$d"
grep -q '^artifact-consumers=0 producer-backed=0 unbacked=0$' "$work/out" \
    && printf '  ok    %-56s\n' "case_8 census is 0/0/0" \
    || { printf '  FAIL  %-56s\n' "case_8 census is 0/0/0"; fails=$((fails + 1)); }

# case_9 -- an empty directory is an error, not a pass. A check that reports
# success because it found nothing to check is the vacuous kind.
d=$work/case_9; mkdir -p "$d"
run "case_9 no workflow files is an error, not a pass" 2 "$d"

# case_10 -- the producer is upstream through a third job. Actions orders the
# whole chain, so the artefact is there when the download runs and this workflow
# is correct. A check that reads only the consumer's own needs: line calls it
# unbacked, which is a false failure pointing the reader at adding a needs edge
# that changes nothing.
d=$work/case_10; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
  fanout:
    needs: [package]
    runs-on: ubuntu-latest
    steps:
      - run: true
  release:
    needs: [fanout]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_10 producer upstream through a third job" 0 "$d"

# case_11 -- a needs cycle. Actions rejects such a workflow, so the verdict
# matters less than the fact that walking the closure has to END. Without a
# visited set this case never returns.
d=$work/case_11; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  first:
    needs: [second]
    runs-on: ubuntu-latest
    steps:
      - run: true
  second:
    needs: [first]
    runs-on: ubuntu-latest
    steps:
      - run: true
  release:
    needs: [first]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
Y
run "case_11 a needs cycle terminates" 1 "$d"

# case_12 -- the consumer needs a producer, and downloads an artefact that
# producer does not upload. Reading the pairing per job passes this: the job
# has A producer. The download fails on the tag with a name nothing in the run
# ever uploaded.
d=$work/case_12; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
        with:
          name: packages-debian
  release:
    needs: [package]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          pattern: 'packages-*'
      - uses: actions/download-artifact@v4
        with:
          name: source-tarball
Y
run "case_12 a named artefact with no producer upstream" 1 "$d"
grep -q "downloads 'source-tarball'" "$work/out" \
    && printf '  ok    %-56s\n' "case_12 names the artefact, not the job" \
    || { printf '  FAIL  %-56s\n' "case_12 names the artefact, not the job"; fails=$((fails + 1)); }

# case_13 -- the matrix case, which must NOT be failed: the consumer asks with
# a pattern and the producer's name is an expression the matrix expands. A
# check that compared the two literally would call this missing.
d=$work/case_13; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  package:
    strategy:
      matrix:
        slug: [debian, ubuntu]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
        with:
          name: packages-${{ matrix.slug }}
  fanout:
    needs: [package]
    runs-on: ubuntu-latest
    steps:
      - run: true
  release:
    needs: [fanout]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          pattern: 'packages-*'
Y
run "case_13 a pattern served through the matrix and a fan-in" 0 "$d"

# case_14 -- a workflow without a consumer beside one with a backed consumer:
# the directory measured something, and the quiet workflow is not failed.
d=$work/case_14; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: true
Y
cat > "$d/b.yml" <<'Y'
name: b
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
        with:
          name: bundle
  release:
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: bundle
Y
run "case_14 a quiet workflow beside a measured one" 0 "$d"

# case_15 -- a pattern that one producer in needs already satisfies, while a
# second producer whose artefact the same pattern collects is NOT in needs.
# The pattern matches, so a per-request "is anything upstream" reading passes,
# and the release publishes without the second producer's files -- whichever
# of the two happens to finish first.
d=$work/case_15; mkdir -p "$d"
cat > "$d/a.yml" <<'Y'
name: a
on: [push]
jobs:
  linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
        with:
          name: linux-artifacts
  tarball:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
        with:
          name: tarball-artifacts
  release:
    needs: [linux]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          pattern: '*-artifacts'
          merge-multiple: true
Y
run "case_15 a pattern whose second producer is not in needs" 1 "$d"
grep -q "tarball" "$work/out" \
    && printf '  ok    %-56s\n' "case_15 the message names the missing producer" \
    || { printf '  FAIL  %-56s\n' "case_15 the message names the missing producer"; fails=$((fails + 1)); }


# ------------------------------------------------ the names and producer arms --
wf() {  # wf <case> <upload-name> <consumer-key> <consumer-value>
    local c=$1 up=$2 key=$3 val=$4 d="$work/$1"
    mkdir -p "$d"
    {
        echo 'name: Fixture'
        echo 'on:'
        echo '  push:'
        echo 'jobs:'
        echo '  produce:'
        echo '    runs-on: ubuntu-latest'
        echo '    steps:'
        echo '      - uses: actions/upload-artifact@v4'
        echo '        with:'
        echo "          name: $up"
        echo '          path: out/*'
        if [ -n "$key" ]; then
            echo '  consume:'
            echo '    needs: produce'
            echo '    runs-on: ubuntu-latest'
            echo '    steps:'
            echo '      - name: Fetch what the other job made'
            echo '        uses: actions/download-artifact@v4'
            echo '        with:'
            echo "          $key: $val"
            echo '          path: artifacts'
        fi
    } > "$d/fixture.yml"
}

# A fixture with a repository around it: the producer arm reads the workflow
# directory's grandparent, which is what .github/workflows makes the root.
wfroot() {  # wfroot <case> <line-naming-the-maker-or-empty>
    local c=$1 line=$2 d="$work/$1/root"
    mkdir -p "$d/ci/scripts" "$d/.github/workflows"
    printf '#!/bin/sh\nexit 0\n' > "$d/ci/scripts/make-source-tarball.sh"
    chmod 755 "$d/ci/scripts/make-source-tarball.sh"
    {
        echo 'name: Fixture'
        echo 'on:'
        echo '  push:'
        echo 'jobs:'
        echo '  produce:'
        echo '    runs-on: ubuntu-latest'
        echo '    steps:'
        [ -n "$line" ] && echo "      $line"
        echo '      - uses: actions/upload-artifact@v4'
        echo '        with:'
        echo '          name: source-tarball'
        echo '          path: out/*'
        echo '  consume:'
        echo '    needs: produce'
        echo '    runs-on: ubuntu-latest'
        echo '    steps:'
        echo '      - uses: actions/download-artifact@v4'
        echo '        with:'
        echo '          name: source-tarball'
    } > "$d/.github/workflows/fixture.yml"
}

# A fixture with a repository around it where the job runs the maker but
# never publishes what it built: no upload-artifact step anywhere in the job.
wfroot_unpublished() {  # wfroot_unpublished <case>
    local c=$1 d="$work/$1/root"
    mkdir -p "$d/ci/scripts" "$d/.github/workflows"
    printf '#!/bin/sh\nexit 0\n' > "$d/ci/scripts/make-source-tarball.sh"
    chmod 755 "$d/ci/scripts/make-source-tarball.sh"
    {
        echo 'name: Fixture'
        echo 'on:'
        echo '  push:'
        echo 'jobs:'
        echo '  produce:'
        echo '    runs-on: ubuntu-latest'
        echo '    steps:'
        echo '      - run: ci/scripts/make-source-tarball.sh out'
    } > "$d/.github/workflows/fixture.yml"
}

expect() {  # expect <case> <want-rc> <substring>
    local c=$1 want=$2 sub=$3 out rc
    cases=$((cases + 1))
    # red-proved: the case in which the gate returned non-zero on a perturbed input.
    if [ "$want" != 0 ]; then red=$((red + 1)); fi
    local d="$work/$c" r="$work/$c"
    [ -d "$d/root/.github/workflows" ] && { r="$d/root"; d="$d/root/.github/workflows"; }
    out=$(REPO_ROOT="$r" bash "$subject" "$d" 2>&1); rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "CASE $c: expected rc=$want, got $rc"
        printf '%s\n' "$out" | sed 's/^/    /'
        fails=$((fails + 1)); return
    fi
    case "$out" in
        *"$sub"*) : ;;
        *) echo "CASE $c: rc was $rc but no line mentions '$sub'"
           printf '%s\n' "$out" | sed 's/^/    /'
           fails=$((fails + 1)) ;;
    esac
}

# 1 -- the hole this gate exists for: an artefact whose name the consumer's
#      pattern cannot match. Built, kept, silently dropped.
wf unmatched_name source-tarball pattern "'*-artifacts'"
expect unmatched_name 1 "artefact 'source-tarball' is uploaded but no download step"

# 2 -- the same hole with a matrix name.
wf unmatched_matrix 'packages-${{ matrix.slug }}' pattern "'pkg-*'"
expect unmatched_matrix 1 "is uploaded but no download step"

# 3 -- a matrix name the pattern DOES cover must pass. An over-strict rule
#      would fail this, and every packaging workflow with it.
wf matched_matrix 'packages-${{ matrix.slug }}' pattern "'packages-*'"
expect matched_matrix 0 "matched=1 unmatched=0"

# 4 -- a consumer that asks for the exact name must pass too.
wf matched_name source-tarball name source-tarball
expect matched_name 0 "matched=1 unmatched=0"

# 5 -- a workflow with no consumer at all is evidence retention. It must not
#      fail, and it must SAY it was skipped: a silent skip is a vacuum. Alone in
#      a directory it is also the whole measurement, so there it is rc=2 (the
#      needs arm's "nothing downloads anything"); beside a measured workflow
#      it is 0.
wf no_consumer abi-snapshot "" ""
expect no_consumer 2 "no consumer -- evidence retention, out of scope"
wf no_consumer_beside abi-snapshot "" ""
mv "$work/no_consumer_beside/fixture.yml" "$work/no_consumer_beside/retention.yml"
wf no_consumer_beside source-tarball name source-tarball
expect no_consumer_beside 0 "no consumer -- evidence retention, out of scope"

# 6 -- nothing to measure is not a pass.
mkdir -p "$work/empty"
expect empty 2 "nothing to check"

# 7 -- the maker is present and no workflow names it. Every artefact name still
#      lines up, so arm 1 is green and only the producer arm speaks.
wfroot producer_missing ''
expect producer_missing 1 "is present but no workflow step runs it"

# 8 -- the maker is named, but only inside a comment. A textual check that
#      counted this would be greenest for whoever writes the least CI.
wfroot producer_commented '# ci/scripts/make-source-tarball.sh used to run here'
expect producer_commented 1 "is present but no workflow step runs it"

# 9 -- the maker is named by a step, and that same job publishes what it
#      built. This is the shape every release workflow in the stack has, and
#      it must pass.
wfroot producer_present '- run: ci/scripts/make-source-tarball.sh out'
expect producer_present 0 "source-tarball-producers=1"

# 10 -- the maker runs, but its job has no upload-artifact step at all: the
#       tarball is built and thrown away. The gate this replaced only asked
#       whether some step named the maker, and stayed green on this exact
#       fixture (measured against the previous check-artifact-names.sh).
wfroot_unpublished producer_unpublished
expect producer_unpublished 1 "but has no actions/upload-artifact step"

# 11 -- control: the release skeleton every consumer's release.yml follows
#       (build jobs upload `*-artifacts`, the seal job collects them by pattern
#       and runs make-source-tarball.sh in a job that uploads it) must pass, and
#       the census lines must say how much was judged.
wfroot control ''
cat > "$work/control/root/.github/workflows/fixture.yml" <<'Y'
name: Release
on:
  push:
    tags: ['[0-9]+.[0-9]+.[0-9]+*']
jobs:
  preflight:
    runs-on: ubuntu-24.04
    steps:
      - run: true
  build-linux:
    needs: [preflight]
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/upload-artifact@0123456789abcdef0123456789abcdef01234567
        with:
          name: linux-artifacts
          path: out/*
  source-tarball:
    needs: [preflight]
    runs-on: ubuntu-24.04
    steps:
      - run: ci/scripts/make-source-tarball.sh out
      - uses: actions/upload-artifact@0123456789abcdef0123456789abcdef01234567
        with:
          name: tarball-artifacts
          path: out/*
  seal:
    needs: [build-linux, source-tarball]
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/download-artifact@0123456789abcdef0123456789abcdef01234567
        with:
          pattern: '*-artifacts'
          merge-multiple: true
          path: artifacts
Y
expect control 0 "source-tarball-producers=1"
out=$(REPO_ROOT="$work/control/root" bash "$subject" "$work/control/root/.github/workflows" 2>&1)
for line in 'uploads-with-a-consumer-in-scope=2 matched=2 unmatched=0' \
            'artifact-consumers=1 producer-backed=1 unbacked=0' \
            'artefact-requests=1 matched=1 unmatched=0'; do
    cases=$((cases + 1))
    case "$out" in
        *"$line"*) printf '  ok    %-56s\n' "control census: $line" ;;
        *) echo "CASE control: no census line '$line'"; printf '%s\n' "$out" | sed 's/^/    /'
           fails=$((fails + 1)) ;;
    esac
done

# 12 -- the consumer's tree is REPO_ROOT, from a foreign cwd, with no argument:
#       the workflows AND the maker are read there, not beside this script and
#       not from a decoy workspace. The fixture is the unpublished producer, so
#       reading the wrong tree could only turn it green.
wfroot_unpublished foreign_cwd
mkdir -p "$work/decoy"
cases=$((cases + 1)); red=$((red + 1))
out=$(cd / && GITHUB_WORKSPACE="$work/decoy" REPO_ROOT="$work/foreign_cwd/root" bash "$subject" 2>&1); rc=$?
case "$rc:$out" in
    1:*"but has no actions/upload-artifact step"*) printf '  ok    %-56s rc=1\n' "foreign cwd judges REPO_ROOT" ;;
    *) echo "CASE foreign_cwd: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1)) ;;
esac
cases=$((cases + 1)); red=$((red + 1))
out=$(cd / && env -u GITHUB_WORKSPACE -u REPO_ROOT bash "$subject" 2>&1); rc=$?
[ "$rc" = 2 ] && printf '  ok    %-56s rc=2\n' "no consumer tree at all" \
    || { echo "CASE no_tree: rc=$rc, want 2"; fails=$((fails + 1)); }

if [ "$fails" -eq 0 ]; then
    echo "check-release-artifacts selftest: all $cases cases passed"
    printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
    exit 0
fi
echo "check-release-artifacts selftest: $fails of $cases case(s) failed"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit 1
