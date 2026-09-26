#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# check-release-artifacts.sh [workflow-dir]
#
# Three arms over one consumer's workflows, each the other's blind spot:
#
#   needs     a job that DOWNLOADS artefacts must depend on a job that UPLOADS
#             them, in the same workflow, per artefact name;
#   names     in a workflow that downloads at all, every artefact UPLOADED must
#             be nameable by some download -- or it is built, kept and dropped;
#   producer  where the consumer ships its make-source-tarball.sh, the job that
#             runs it also uploads what it built.
#
# The needs arm sees a consumer that lost its producer; the names arm sees a
# producer that lost its consumer; neither sees a tarball built and thrown away.
# They were two scripts in every repository; they are one here so that no
# repository can run one arm and believe it ran the question.
#
# The consumer's tree is REPO_ROOT (default $GITHUB_WORKSPACE, then the git
# toplevel of the current directory), never this script's location. The
# workflow directory defaults to $REPO_ROOT/.github/workflows; the maker is
# $REPO_ROOT/${MAKE_SOURCE_TARBALL:-ci/scripts/make-source-tarball.sh}.
#
# ---- needs arm
#
# A job that DOWNLOADS artefacts must depend on a job that UPLOADS them, in the
# same workflow.
#
# Measured on this repository before this check existed: release.yml downloaded
# `pattern: '*'` into artifacts/ while no job in that workflow uploaded
# anything. actions/download-artifact neither fails on an empty match nor
# creates its target directory, so the next step ran `find artifacts` against a
# path that does not exist and the release job died there -- five steps before
# `gh release create`, leaving no Release object, no SBOM and no SHA256SUMS.
# Nothing in CI said so, because nothing read this pairing.
#
# `needs` is half the invariant and not a formality: download-artifact without
# a run-id sees only artefacts that jobs of the SAME run have already finished
# uploading, so a producer that is not upstream of the consumer is a race, not
# a producer.
#
# The pairing is read per ARTEFACT, not per job. A release job that downloads
# two named artefacts and needs one producer used to pass on the strength of
# that one: dropping the other producer from `needs` left the census reading
# backed, and the failure waited for the tag, where download-artifact errors
# out with a name nothing in the run uploaded. So every `name:` and `pattern:`
# a consumer asks for must be matched by an artefact name uploaded somewhere in
# its transitive needs closure. A download step with neither key asks for
# everything in the run, and any producer upstream answers it. `${{ ... }}` on
# either side stands for anything, because that is what a matrix expands to.
#
# Upstream means the TRANSITIVE closure of `needs`, not the direct list. A
# workflow that puts a fan-in or summary job between the producer and the
# consumer still orders them, so it is correct and must not be failed here; the
# walk carries a visited set, so a needs cycle terminates instead of recursing
# forever. The message still names the direct `needs`, because that is the line
# the reader has to edit.
#
# Deliberately not a YAML-library parse, for the same reason as
# check-job-timeouts.sh: a job that runs inside a minimal container would need
# an extra package for that, and the indentation is exact enough for the
# distinctions that matter -- a job key is two spaces, its own keys four, its
# steps six.
#
# Threat model. This reads workflow TEXT, so it guards against the honest
# regression: someone adds a consumer job, or drops a producer, writing the
# shapes this repository actually writes, and nothing else notices. It cannot
# and does not resist a workflow written to conceal intent, and these doors are
# left open knowingly: a producer step supplied through a composite action or a
# reusable workflow rather than a `uses: actions/upload-artifact` line here; a
# job key written with other than two spaces of indentation; and a producer
# that uploads ZERO files, which is a valid upload and passes. The
# last one is why the release job additionally asserts at run time that the
# artefacts arrived, and why its upload sets `if-no-files-found: error`. Code
# review, not this gate, is what catches a deliberately misleading workflow.
#
# One more door, named because it is the one that fails SILENTLY: `uses:` and
# `needs:` are matched as bare scalars, so a quoted spelling -- `uses:
# 'actions/download-artifact@v4'`, or `needs: ['a','b']` -- is not seen. A
# quoted consumer disappears from the census, a quoted producer or a quoted
# `needs` list is reported as unbacked. No workflow in these repositories
# writes either shape today. The consequence to keep in mind when reading the
# census: `artifact-consumers=0` means no consumer was PARSED, which is how
# every workflow without a download looks and also how one written this way
# would look.
#
# A pattern request is held to EVERY producer whose upload it matches, not to
# the first: a release that collects '*-artifacts' and needs only one of three
# producers matches, and publishes whatever has finished.
#
# ---- names and producer arms
#
# An artefact that is uploaded and never downloaded is built, kept for ninety
# days and silently dropped from the release. The shape, which costs nothing to
# write and nothing to notice: a job uploads `source-tarball` into a workflow
# whose release job collects its inputs with `pattern: '*-artifacts'`. Nothing
# fails. download-artifact is happy with an empty match, every gate stays green,
# and the release simply carries no source tarball -- while the packaging recipe
# points at the asset that was never published.
#
# So: in a workflow that downloads artefacts at all, every uploaded artefact
# name must be matched by some consumer's `name:` or `pattern:` in that same
# workflow. `${{ ... }}` inside an uploaded name stands for anything, because
# that is what a matrix expands to.
#
# A workflow with NO consumer is out of scope and is printed as such. Uploads
# there are evidence retention -- an ABI snapshot, a fuzz crash, a package to
# download by hand from the run page -- and demanding a consumer for those
# would be demanding the wrong thing.
#
# Second arm, the other direction, for the one asset with a contract outside
# this repository. The source tarball the packaging recipes fetch by URL is
# built by one workflow step and has to be published by another; if the build
# step is dropped the release publishes no tarball, every gate here stays
# green, and the recipe's `source=` 404s for everyone at the next tag. The
# wiring check does not see it either: reachability there is TRANSITIVE, and
# make-source-tarball.sh is named in code by the recipe check and by this
# gate itself, so it counts as wired even when no workflow names it at
# all (measured -- deleting the whole job left that check green). Dropping
# only the upload step is the quieter half of the same hole: the run step
# that builds the tarball is untouched, so a check that only asked whether
# some step names the maker stayed green while the job built the tarball and
# threw it away (measured on a copy with just that step removed). So: where
# the script is present, the job that runs it must also carry a
# `uses: actions/upload-artifact` step of its own. Where the script is not
# present the arm says so rather than passing quietly.
#
# The names arm checks NAMES only. Whether the consumer is downstream of the
# producer is the needs arm's question, and a name can match while the
# ordering is still wrong, and vice versa. Before the two were one script, a
# repository could carry this arm without that one, and there nothing measured
# the ordering at all.
#
# Threat model. This reads workflow TEXT, so it guards against the honest
# regression: someone adds an upload, or renames one, in the shapes these
# workflows actually use, and no run says the artefact stopped arriving. It
# does not resist a workflow written to conceal intent, and these doors are
# left open knowingly: an upload or download supplied through a composite
# action or reusable workflow rather than a `uses: actions/upload-artifact`
# line here; a quoted `uses: 'actions/upload-artifact@v4'`, which is not seen
# at all; a name built by an expression whose expansion never matches the
# pattern, since `${{ ... }}` is read as "anything"; and an upload whose
# `if:` condition is false in practice. One more door is worth naming because
# it is the one that fails quietly: a workflow that loses its LAST download
# step falls out of scope as a whole, and its uploads stop being measured here
# at all. The neighbouring check sees a consumer that lost its producer, never
# a producer that lost its consumer. Code review, not this gate, is what
# catches a workflow written to mislead.
#
# Exit: 0 every arm holds - 1 one does not - 2 nothing could be measured (no
#       workflow, no consumer tree, or no consumer in any workflow) -- NOT a
#       pass.
set -u

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "FATAL: needs bash >= 4 -- cannot judge" >&2; exit 2; }
root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
[ -n "$root" ] && [ -d "$root" ] \
    || { echo "FATAL: no consumer tree (set REPO_ROOT) -- cannot judge" >&2; exit 2; }
dir=${1:-$root/.github/workflows}
rc=0
consumers=0
backed=0
requests=0
matched=0

shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
    echo "no workflow files under $dir -- nothing to check, and that is not a pass" >&2
    exit 2
fi

for f in "${files[@]}"; do
    while read -r kind job verdict rest; do
        if [ "$kind" = REQ ]; then
            requests=$((requests + 1))
            case "$verdict" in
                ok)
                    matched=$((matched + 1)) ;;
                missing)
                    echo "::error file=$f::job '$job' downloads '$rest' but no job in its needs closure uploads an artefact by that name -- the download fails on the tag, where it cannot be taken back"
                    rc=1 ;;
                stray)
                    echo "::error file=$f::job '$job' collects ${rest#* } with a pattern that also matches what job '${rest%% *}' uploads, and '${rest%% *}' is not in its needs closure -- the release takes whatever has finished, and may publish without it"
                    rc=1 ;;
            esac
            continue
        fi
        consumers=$((consumers + 1))
        case "$verdict" in
            ok)
                backed=$((backed + 1)) ;;
            partial)
                : ;;
            noneeds)
                echo "::error file=$f::job '$job' downloads artefacts but declares no needs: -- nothing guarantees a producer ran first"
                rc=1 ;;
            unbacked)
                echo "::error file=$f::job '$job' downloads artefacts but none of the jobs it needs ($rest) uploads any"
                rc=1 ;;
        esac
    done < <(awk '
        # A step ends the artefact block it opened: the name that belongs to an
        # upload or download step is the one inside its own with:.
        function flush(   ) {
            if (mode == "up"   && pend) upn[cur]  = upn[cur]  " artifact"
            if (mode == "down" && pend) dreq[cur] = dreq[cur] " *"
            mode = ""; pend = 0
        }
        function val(line,   v) {
            v = line
            sub(/^[[:space:]]*[A-Za-z-]+:[[:space:]]*/, "", v)
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/^["'"'"']|["'"'"']$/, "", v)
            sub(/[[:space:]]+$/, "", v)
            return v
        }
        # A matrix expression stands for anything the matrix can produce.
        function expand(x) {
            while (match(x, /\$\{\{[^}]*\}\}/))
                x = substr(x, 1, RSTART - 1) "*" substr(x, RSTART + RLENGTH)
            return x
        }
        # The consumer asks with a glob; turn it into a regex so an upload name
        # can be tested against it. Everything else is matched literally.
        function globre(g,   i, c, out) {
            out = "^"
            for (i = 1; i <= length(g); i++) {
                c = substr(g, i, 1)
                if (c == "*") out = out ".*"
                else if (c == "?") out = out "."
                else if (index(".^$+()[]{}|\\", c) > 0) out = out "\\" c
                else out = out c
            }
            return out "$"
        }
        /^jobs:[[:space:]]*$/ { inj = 1; next }
        inj && /^[^[:space:]#]/ { flush(); inj = 0 }
        # A job key: exactly two spaces, a name, a colon, nothing after it.
        inj && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
            flush()
            cur = $1; sub(/:$/, "", cur)
            order[++n] = cur; up[cur] = 0; down[cur] = 0; needs[cur] = ""
            upn[cur] = ""; dreq[cur] = ""
            inneeds = 0
            next
        }
        cur == "" { next }
        # Only a uses: line counts. A comment that mentions the action, or a
        # step named after it, must not stand in for one that runs it.
        /^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*actions\/upload-artifact/   { flush(); up[cur] = 1;   mode = "up";   pend = 1; next }
        /^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*actions\/download-artifact/ { flush(); down[cur] = 1; mode = "down"; pend = 1; next }
        # needs at JOB level is four spaces. Three spellings: scalar, flow list,
        # block list.
        /^    needs:/ {
            flush()
            line = $0
            sub(/^[[:space:]]*needs:[[:space:]]*/, "", line)
            gsub(/[][,]/, " ", line)
            needs[cur] = needs[cur] " " line
            inneeds = 1
            next
        }
        # A new four-space key ends the block list.
        /^    [^ ]/ { inneeds = 0 }
        inneeds && /^      -[[:space:]]/ {
            item = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", item)
            needs[cur] = needs[cur] " " item
            next
        }
        # Any other step boundary closes the block.
        /^[[:space:]]*-[[:space:]]/ { flush() }
        mode == "up"   && /^[[:space:]]*name:[[:space:]]*[^[:space:]]/    { upn[cur]  = upn[cur]  " " val($0); mode = ""; pend = 0; next }
        mode == "down" && /^[[:space:]]*name:[[:space:]]*[^[:space:]]/    { dreq[cur] = dreq[cur] " " val($0); pend = 0; next }
        mode == "down" && /^[[:space:]]*pattern:[[:space:]]*[^[:space:]]/ { dreq[cur] = dreq[cur] " " val($0); pend = 0; next }
        # A producer anywhere in the closure of needs is upstream of the
        # consumer. seen guards against a cycle: an illegal workflow must make
        # this exit, not hang.
        function backed(j, seen,   m, t, k, c) {
            m = split(needs[j], t, /[[:space:]]+/)
            for (k = 1; k <= m; k++) {
                c = t[k]
                if (c == "" || (c in seen)) continue
                seen[c] = 1
                if (up[c]) return 1
                if (backed(c, seen)) return 1
            }
            return 0
        }
        # The same walk, but asking whether the artefact this consumer NAMES is
        # uploaded anywhere upstream.
        function serves(j, re, seen,   m, t, k, c, nn, q, i) {
            m = split(needs[j], t, /[[:space:]]+/)
            for (k = 1; k <= m; k++) {
                c = t[k]
                if (c == "" || (c in seen)) continue
                seen[c] = 1
                nn = split(upn[c], q, /[[:space:]]+/)
                for (i = 1; i <= nn; i++)
                    if (q[i] != "" && expand(q[i]) ~ re) return 1
                if (serves(c, re, seen)) return 1
            }
            return 0
        }
        function closure(j, reach,   m, t, k, c) {
            m = split(needs[j], t, /[[:space:]]+/)
            for (k = 1; k <= m; k++) {
                c = t[k]
                if (c == "" || (c in reach)) continue
                reach[c] = 1
                closure(c, reach)
            }
        }
        END {
            flush()
            for (i = 1; i <= n; i++) {
                j = order[i]
                if (!down[j]) continue
                if (needs[j] ~ /^[[:space:]]*$/) { printf "JOB %s noneeds -\n", j; continue }
                delete seen
                if (!backed(j, seen)) {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", needs[j])
                    printf "JOB %s unbacked %s\n", j, needs[j]
                    continue
                }
                bad = 0
                m = split(dreq[j], t, /[[:space:]]+/)
                for (k = 1; k <= m; k++) {
                    r = t[k]
                    if (r == "") continue
                    delete seen
                    re = globre(expand(r))
                    if (!serves(j, re, seen)) { printf "REQ %s missing %s\n", j, r; bad = 1; continue }
                    # Every producer whose upload the request matches has to be
                    # upstream, not just one: a pattern one producer satisfies
                    # is still missing the others.
                    delete reach
                    closure(j, reach)
                    stray = 0
                    for (o = 1; o <= n; o++) {
                        p = order[o]
                        if (p == j || (p in reach)) continue
                        nn = split(upn[p], q, /[[:space:]]+/)
                        for (x = 1; x <= nn; x++)
                            if (q[x] != "" && expand(q[x]) ~ re) {
                                printf "REQ %s stray %s %s\n", j, p, r; stray = 1; bad = 1; break
                            }
                    }
                    if (!stray) printf "REQ %s ok %s\n", j, r
                }
                printf "JOB %s %s -\n", j, (bad ? "partial" : "ok")
            }
        }
    ' "$f")
done

# ---- names arm
uploads=0
matched_up=0
extract() {  # extract <file> -> "UP <name>" / "DOWN <glob>" lines
    awk '
        function val(line,   v) {
            v = line
            sub(/^[[:space:]]*[A-Za-z-]+:[[:space:]]*/, "", v)
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/^["'"'"']|["'"'"']$/, "", v)
            sub(/[[:space:]]+$/, "", v)
            return v
        }
        /uses:[[:space:]]*actions\/upload-artifact/   { mode = "up";   next }
        /uses:[[:space:]]*actions\/download-artifact/ { mode = "down"; next }
        /^[[:space:]]*-[[:space:]]/ { mode = "" }
        /^[^[:space:]#]/            { mode = "" }
        mode == "up"   && /^[[:space:]]*name:[[:space:]]*[^[:space:]]/    { print "UP " val($0); mode = ""; next }
        mode == "down" && /^[[:space:]]*name:[[:space:]]*[^[:space:]]/    { print "DOWN " val($0); next }
        mode == "down" && /^[[:space:]]*pattern:[[:space:]]*[^[:space:]]/ { print "DOWN " val($0); next }
    ' "$1"
}

for f in "${files[@]}"; do
    mapfile -t lines < <(extract "$f")
    ups=(); downs=()
    for l in "${lines[@]}"; do
        case "$l" in
            "UP "*)   ups+=("${l#UP }") ;;
            "DOWN "*) downs+=("${l#DOWN }") ;;
        esac
    done
    [ "${#ups[@]}" -eq 0 ] && continue
    if [ "${#downs[@]}" -eq 0 ]; then
        printf '%s: %d upload(s), no consumer -- evidence retention, out of scope\n' "$f" "${#ups[@]}"
        continue
    fi
    for u in "${ups[@]}"; do
        uploads=$((uploads + 1))
        # A matrix expression stands for anything the matrix can produce.
        subject=$u
        while [ "$subject" != "${subject/\$\{\{*\}\}/*}" ]; do subject=${subject/\$\{\{*\}\}/*}; done
        hit=""
        for d in "${downs[@]}"; do
            # shellcheck disable=SC2254  # the consumer's value IS a glob
            case "$subject" in
                $d) hit=$d; break ;;
            esac
        done
        if [ -n "$hit" ]; then
            matched_up=$((matched_up + 1))
            printf "%s: upload '%s' is downloaded by '%s'\n" "$f" "$u" "$hit"
        else
            echo "::error file=$f::artefact '$u' is uploaded but no download step in this workflow can name it -- it would be built, kept and silently dropped"
            rc=1
        fi
    done
done
printf 'uploads-with-a-consumer-in-scope=%d matched=%d unmatched=%d\n' \
    "$uploads" "$matched_up" "$((uploads - matched_up))"

# ---- producer arm

# The producer arm. A job "runs" the maker if some non-comment line names it;
# that same job must also carry an upload-artifact step, or the tarball it
# builds is never published.
maker=${MAKE_SOURCE_TARBALL:-ci/scripts/make-source-tarball.sh}
if [ -f "$root/$maker" ]; then
    producers=0
    job=""
    has_maker=0
    has_upload=0
    flush_job() {
        [ "$has_maker" -eq 1 ] || return 0
        producers=$((producers + 1))
        if [ "$has_upload" -eq 1 ]; then
            printf '%s: job %s runs %s and publishes it\n' "$f" "$job" "$maker"
        else
            echo "::error file=$f::job '$job' runs $maker but has no actions/upload-artifact step of its own -- the tarball would be built and thrown away, and the packaging recipes fetch that asset by URL"
            rc=1
        fi
    }
    for f in "${files[@]}"; do
        job=""; has_maker=0; has_upload=0
        while IFS=$'\t' read -r tag rest; do
            case "$tag" in
                JOB)    flush_job; job=$rest; has_maker=0; has_upload=0 ;;
                MAKER)  has_maker=1 ;;
                UPLOAD) has_upload=1 ;;
            esac
        done < <(awk -v m="$(basename -- "$maker")" '
            /^jobs:[[:space:]]*$/               { seen = 1; next }
            seen && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
                j = $0
                sub(/^  /, "", j); sub(/:[[:space:]]*$/, "", j)
                print "JOB\t" j
                next
            }
            /^[[:space:]]*#/ { next }
            index($0, m) > 0                             { print "MAKER" }
            /uses:[[:space:]]*actions\/upload-artifact/  { print "UPLOAD" }
        ' "$f")
        flush_job
    done
    if [ "$producers" -eq 0 ]; then
        echo "::error::$maker is present but no workflow step runs it -- the release would publish no source tarball, and the packaging recipes fetch that asset by URL"
        rc=1
    fi
    printf 'source-tarball-producers=%d\n' "$producers"
else
    printf 'no %s here -- the producer arm does not apply\n' "$maker"
fi

printf 'artifact-consumers=%d producer-backed=%d unbacked=%d\n' "$consumers" "$backed" "$((consumers - backed))"
printf 'artefact-requests=%d matched=%d unmatched=%d\n' "$requests" "$matched" "$((requests - matched))"
# Nothing downloaded anywhere is nothing measured: the census reads 0/0/0 for
# a repository with no consumer and for one whose consumer this parser cannot
# see. A repository that has nothing to download records that in its
# gate-wiring exceptions rather than running this.
if [ "$rc" -eq 0 ] && [ "$consumers" -eq 0 ]; then
    echo "no workflow under $dir downloads an artefact -- nothing was measured, and that is not a pass" >&2
    exit 2
fi
exit "$rc"
