#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# aur-publish.sh -- publish each repository's tagged Arch recipe to the AUR,
# unchanged, with the .SRCINFO makepkg derives from it.
#
# Usage: aur-publish.sh --sources <dir> --remote-base <url>
#                       [--ssh-key <file>] [--known-hosts <file>]
#
#   --sources      holds one checkout per repository (<dir>/LibreMiddleware,
#                  ...), each at its release tag and with its git index. It
#                  must include packaging/arch/, KEYS, VERSION,
#                  .github/workflows/ci.yml (where the recipe gate's options
#                  are read) and every file those options name; the gate reads
#                  the submodule pins from the index
#   --remote-base  <remote-base>/<pkgbase>.git is the AUR repository
#                  (ssh://aur@aur.archlinux.org on a publish, file:// in tests;
#                  the AUR takes pushes only over SSH)
#   --ssh-key      the AUR key; required for an ssh:// remote
#   --known-hosts  default keys/aur-known-hosts; the host key is never learnt
#
# Runs in `pkg-images tool-image archlinux`. As root it installs git, openssh
# and python-yaml (-Syu: a package synced without the rest of the image can
# need newer libraries than the image has), creates the unprivileged user `builder` (UID 1000) and runs the rest
# as builder, because makepkg refuses root. Run as anyone else, it is that user.
#
# Per pkgbase, in the table's order: clone the AUR repository (a new pkgbase
# clones empty, so a failed clone is never "no repository yet"), copy
# packaging/arch/PKGBUILD in byte for byte, run check-recipe through
# run-gates.py with the recipe-args of the one actions/gates step in the
# checkout's own ci.yml that runs it (the options that gated this very tag),
# import its KEYS into a GNUPGHOME of its own, makepkg --verifysource (the
# tag's signature), write .SRCINFO, require its pkgbase to be the table's and
# the copy to be the PKGBUILD at that verified tag, and commit when something
# changed. Only when every pkgbase is green is anything
# pushed, so one bad recipe never leaves the AUR half published. Nothing to
# commit is no push: a re-run is a no-op.
#
# Exit codes: 0 published (or nothing changed); 1 a finding (a recipe gate, a
# signature, a recipe that is not the tagged one, a rejected push) -- nothing
# pushed unless only a push failed; 2 cannot judge (bad usage, a missing
# checkout, file or tool, a ci.yml without exactly one check-recipe step, no
# usable builder, a clone, download or push that did not connect, a step over
# its deadline).
set -uo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
here="$(dirname -- "$self")"

# pkgbase -> repository. The pkgbase is also what the recipe's .SRCINFO must
# say.
PKGBASES=(librescrs-middleware libreagent librelinux librecelik librekde)
declare -A REPO=(
    [librescrs-middleware]=LibreMiddleware [libreagent]=LibreAgent
    [librelinux]=LibreLinux [librecelik]=LibreCelik [librekde]=LibreKDE
)

# recipe_args CI_YML -> the recipe-args of the one LibreSCRS/ci actions/gates
# step whose gates include check-recipe; exit 2 when there is not exactly one
# (a step that was never run gated nothing).
recipe_args() {
    python3 -I - "$1" <<'EOF'
import sys
import yaml
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
except (OSError, UnicodeDecodeError, yaml.YAMLError) as e:
    sys.exit(f"{path} cannot be read as YAML: {e}".replace("\n", " "))
jobs = doc.get("jobs") if isinstance(doc, dict) else None
if not isinstance(jobs, dict):
    sys.exit(f"{path} has no jobs mapping")
hits = []
for name, job in jobs.items():
    steps = job.get("steps") if isinstance(job, dict) else None
    for step in steps if isinstance(steps, list) else []:
        if not isinstance(step, dict):
            continue
        uses, args = str(step.get("uses", "")), step.get("with")
        args = args if isinstance(args, dict) else {}
        if uses.startswith("LibreSCRS/ci/actions/gates@") and "check-recipe" in str(args.get("gates", "")).split():
            hits.append((name, args.get("recipe-args", "")))
if len(hits) != 1:
    sys.exit(f"{path}: {len(hits)} actions/gates steps run check-recipe"
             f"{' (jobs ' + ', '.join(n for n, _ in hits) + ')' if hits else ''}; exactly one is needed")
value = hits[0][1]
if value is None:
    value = ""
if not isinstance(value, str):
    sys.exit(f"{path}: recipe-args is not a string")
sys.stdout.write(value)
EOF
}

die2() { echo "aur-publish: $* -- cannot judge" >&2; exit 2; }
usage() { die2 "usage: $(basename -- "$0") --sources DIR --remote-base URL [--ssh-key FILE] [--known-hosts FILE]"; }

SOURCES="" REMOTE="" SSH_KEY="" KNOWN_HOSTS="$here/../keys/aur-known-hosts"
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
        --sources) SOURCES="$2" ;;
        --remote-base) REMOTE="${2%/}" ;;
        --ssh-key) SSH_KEY="$2" ;;
        --known-hosts) KNOWN_HOSTS="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$SOURCES" ] && [ -n "$REMOTE" ] || usage
[ -d "$SOURCES" ] || die2 "--sources '$SOURCES' is not a directory"
SOURCES="$(cd -- "$SOURCES" && pwd)"
case "$REMOTE" in
    ssh://*) [ -n "$SSH_KEY" ] || die2 "an ssh:// remote needs --ssh-key" ;;
    file://*) ;;
    *) die2 "--remote-base '$REMOTE' is not ssh:// or file://" ;;
esac
if [ -n "$SSH_KEY" ]; then
    [ -s "$SSH_KEY" ] || die2 "no SSH key at '$SSH_KEY'"
    [ -s "$KNOWN_HOSTS" ] || die2 "no known-hosts file at '$KNOWN_HOSTS'"
fi
for b in "${PKGBASES[@]}"; do
    s="$SOURCES/${REPO[$b]}"
    for f in packaging/arch/PKGBUILD KEYS VERSION .github/workflows/ci.yml; do
        [ -f "$s/$f" ] || die2 "$b: no $f in $s"
    done
done

# --- root: tools and builder, then the rest as builder ------------------------
if [ "$(id -u)" = 0 ]; then
    timeout -k 30 900 pacman -Syu --noconfirm git openssh python python-yaml >/dev/null \
        || die2 "pacman could not install git, openssh and python-yaml"
    if uid="$(id -u builder 2>/dev/null)"; then
        [ "$uid" = 1000 ] || die2 "the user builder exists with UID $uid, not 1000"
    elif other="$(getent passwd 1000)"; then
        die2 "no user builder, and UID 1000 is taken by '${other%%:*}'"
    else
        useradd -m -u 1000 builder || die2 "useradd could not create builder"
    fi
    stage="$(mktemp -d /var/tmp/aur-stage.XXXXXX)" || die2 "no temporary directory"
    args=(--sources "$SOURCES" --remote-base "$REMOTE")
    if [ -n "$SSH_KEY" ]; then
        if ! { command cp -f "$SSH_KEY" "$stage/key" && command cp -f "$KNOWN_HOSTS" "$stage/known_hosts"; }; then
            rm -rf "$stage"; die2 "could not stage the SSH key"
        fi
        args+=(--ssh-key "$stage/key" --known-hosts "$stage/known_hosts")
    fi
    if ! { chown -R builder: "$stage" && chmod -R go= "$stage"; }; then
        rm -rf "$stage"; die2 "could not hand the stage to builder"
    fi
    runuser -u builder -- env HOME=/home/builder USER=builder LOGNAME=builder \
        bash "$self" "${args[@]}"
    rc=$?
    rm -rf "$stage"
    exit "$rc"
fi

# --- unprivileged ------------------------------------------------------------
for t in git makepkg gpg gpgconf timeout cmp python3; do
    command -v "$t" >/dev/null 2>&1 || die2 "$t is not on PATH"
done
[ -z "$SSH_KEY" ] || command -v ssh >/dev/null 2>&1 || die2 "ssh is not on PATH"
python3 -I -c 'import yaml' 2>/dev/null || die2 "python3 cannot import yaml"

work="$(mktemp -d "${TMPDIR:-/var/tmp}/aur-publish.XXXXXX")" || die2 "no temporary directory"
homes=()
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    local h
    for h in "${homes[@]}"; do GNUPGHOME="$h" gpgconf --kill all >/dev/null 2>&1; rm -rf "$h"; done
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM

# The checkouts belong to whoever checked them out, not to this user; without
# this git refuses them as dubious, and an index read that fails reads as a
# tree with no submodules.
export GIT_CONFIG_COUNT=0
for b in "${PKGBASES[@]}"; do
    export "GIT_CONFIG_KEY_$GIT_CONFIG_COUNT=safe.directory" "GIT_CONFIG_VALUE_$GIT_CONFIG_COUNT=$SOURCES/${REPO[$b]}"
    GIT_CONFIG_COUNT=$((GIT_CONFIG_COUNT + 1))
done
for b in "${PKGBASES[@]}"; do
    git -C "$SOURCES/${REPO[$b]}" ls-files -s >/dev/null 2>&1 \
        || die2 "$b: $SOURCES/${REPO[$b]} has no readable git index"
done

if [ -n "$SSH_KEY" ]; then
    umask 077
    { command cp -f "$SSH_KEY" "$work/key" && command cp -f "$KNOWN_HOSTS" "$work/known_hosts"; } \
        || die2 "could not copy the SSH key"
    export GIT_SSH_COMMAND
    GIT_SSH_COMMAND="ssh -i $(printf %q "$work/key") -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$(printf %q "$work/known_hosts")"
    umask 022
fi

GIT_ID=(-c user.name=hirashix0 -c user.email=hirashix0@proton.me -c commit.gpgsign=false)
findings=0 unjudged=0
declare -A pending=()
finding() { echo "::error::aur-publish: $1: $2"; findings=$((findings + 1)); }
cannot() { echo "aur-publish: $1: $2 -- cannot judge"; unjudged=$((unjudged + 1)); }

prepare() {  # prepare PKGBASE -- 0 ready, 1 a finding, 2 cannot judge
    local b="$1" repo="${REPO[$1]}" src="$SOURCES/${REPO[$1]}" d="$work/aur/$1" rc gh m pkgver ra

    ra="$(recipe_args "$src/.github/workflows/ci.yml" 2>"$work/ra.err")" \
        || { cannot "$b" "recipe-args: $(tail -n 1 "$work/ra.err")"; return 2; }
    echo "aur-publish: $b: recipe-args from ${repo}'s ci.yml: '${ra}'"

    mkdir -p "$work/aur"
    timeout -k 10 300 git clone -q "$REMOTE/$b.git" "$d" 2>"$work/clone.err"
    rc=$?
    case "$rc" in
        0) ;;
        124|137) cannot "$b" "git clone of $REMOTE/$b.git over its deadline"; return 2 ;;
        *) cannot "$b" "git clone of $REMOTE/$b.git failed (rc $rc): $(tail -n 1 "$work/clone.err")"; return 2 ;;
    esac
    # an empty clone (a new pkgbase) sits on whatever the default branch is
    git -C "$d" rev-parse -q --verify HEAD >/dev/null || git -C "$d" symbolic-ref HEAD refs/heads/master

    command cp -f "$src/packaging/arch/PKGBUILD" "$d/PKGBUILD" || { cannot "$b" "copy PKGBUILD"; return 2; }
    cmp -s "$src/packaging/arch/PKGBUILD" "$d/PKGBUILD" || { cannot "$b" "the copied PKGBUILD differs"; return 2; }

    # The tagged original, so the README beside it is judged too; the copy is
    # byte-identical. run-gates.py is the entry the repository's CI ran, so the
    # options are split the same way.
    python3 -I "$here/run-gates.py" --gates check-recipe --root "$src" --repo "$repo" \
        --recipe-args="$ra" 2>&1 | sed "s/^/  [$b] /"
    rc="${PIPESTATUS[0]}"
    case "$rc" in
        0) ;;
        1) finding "$b" "check-recipe is red for $repo"; return 1 ;;
        *) cannot "$b" "check-recipe (rc $rc)"; return 2 ;;
    esac

    gh="$(mktemp -d /var/tmp/lg.XXXXXX)" || { cannot "$b" "no GNUPGHOME"; return 2; }
    homes+=("$gh")
    GNUPGHOME="$gh" gpg --batch --quiet --import "$src/KEYS" >/dev/null 2>&1 \
        || { cannot "$b" "gpg could not import $src/KEYS"; return 2; }

    mkdir -p "$work/src/$b" "$work/build/$b"
    (cd "$d" && GNUPGHOME="$gh" SRCDEST="$work/src/$b" BUILDDIR="$work/build/$b" \
        timeout -k 10 900 makepkg --verifysource --noconfirm) >"$work/$b.makepkg" 2>&1
    rc=$?
    sed "s/^/  [$b] /" "$work/$b.makepkg"
    case "$rc" in
        0) ;;
        124|137) cannot "$b" "makepkg --verifysource over its deadline"; return 2 ;;
        *)
            # makepkg exits 1 for a bad signature, a bad sum and a failed
            # download alike; only its own words tell them apart.
            if grep -q 'Failure while downloading' "$work/$b.makepkg"; then
                cannot "$b" "makepkg --verifysource could not download a source (rc $rc; see its output above)"; return 2
            elif grep -q 'PGP signatures could not be verified' "$work/$b.makepkg"; then
                finding "$b" "makepkg --verifysource: the tag's signature did not verify (rc $rc)"; return 1
            fi
            finding "$b" "makepkg --verifysource failed (rc $rc; see its output above)"; return 1 ;;
    esac

    (cd "$d" && makepkg --printsrcinfo >.SRCINFO) 2>"$work/srcinfo.err" \
        || { cannot "$b" "makepkg --printsrcinfo: $(tail -n 1 "$work/srcinfo.err")"; return 2; }
    [ "$(sed -n 's/^pkgbase = //p' "$d/.SRCINFO")" = "$b" ] \
        || { finding "$b" "the recipe's pkgbase is '$(sed -n 's/^pkgbase = //p' "$d/.SRCINFO")', not $b"; return 1; }
    pkgver="$(sed -n 's/^[[:space:]]*pkgver = //p' "$d/.SRCINFO" | head -n 1)"
    [ -n "$pkgver" ] || { cannot "$b" ".SRCINFO names no pkgver"; return 2; }

    # The signature covers the tag; this ties what is published to it.
    mapfile -t m < <(find "$work/src/$b" -mindepth 1 -maxdepth 1 -type d)
    [ "${#m[@]}" -eq 1 ] || { cannot "$b" "expected one git source in SRCDEST, found ${#m[@]}"; return 2; }
    git -C "${m[0]}" show "refs/tags/$pkgver:packaging/arch/PKGBUILD" >"$work/$b.tagged" 2>/dev/null \
        || { cannot "$b" "no packaging/arch/PKGBUILD at the verified tag $pkgver"; return 2; }
    cmp -s "$work/$b.tagged" "$d/PKGBUILD" \
        || { finding "$b" "packaging/arch/PKGBUILD in $src is not the one at the signed tag $pkgver"; return 1; }

    git -C "$d" add PKGBUILD .SRCINFO || { cannot "$b" "git add"; return 2; }
    if git -C "$d" diff --cached --quiet; then
        echo "aur-publish: $b: unchanged, nothing to push"
        return 0
    fi
    git -C "$d" "${GIT_ID[@]}" commit -q -m "Update to $(sed -n 's/^[[:space:]]*pkgver = //p' "$d/.SRCINFO")-$(sed -n 's/^[[:space:]]*pkgrel = //p' "$d/.SRCINFO")" \
        || { cannot "$b" "git commit"; return 2; }
    pending[$b]=1
    echo "aur-publish: $b: committed $(git -C "$d" rev-parse --short HEAD)"
}

for b in "${PKGBASES[@]}"; do
    echo "-- $b (${REPO[$b]})"
    prepare "$b"
done

if [ "$findings" -gt 0 ] || [ "$unjudged" -gt 0 ]; then
    echo "aur-publish: nothing pushed: $findings finding(s), $unjudged step(s) not judged"
    [ "$findings" -gt 0 ] && exit 1
    exit 2
fi

pushed=0
for b in "${PKGBASES[@]}"; do
    [ -n "${pending[$b]+x}" ] || continue
    timeout -k 10 300 git -C "$work/aur/$b" push -q origin HEAD:master
    rc=$?
    case "$rc" in
        0) pushed=$((pushed + 1)); echo "aur-publish: $b: pushed" ;;
        124|137) cannot "$b" "git push over its deadline" ;;
        1) finding "$b" "git push to $REMOTE/$b.git was refused" ;;
        *) cannot "$b" "git push to $REMOTE/$b.git failed (rc $rc)" ;;
    esac
done
echo "aur-publish: $pushed pushed, $((${#PKGBASES[@]} - ${#pending[@]})) unchanged"
[ "$findings" -eq 0 ] || exit 1
[ "$unjudged" -eq 0 ] || exit 2
exit 0
