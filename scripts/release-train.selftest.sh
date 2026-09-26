#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC2016  # fixture and perturbation text is literal on purpose
# Self-test for release-train, over fake remotes.
#
# Each case builds a world: eight bare "origin" repositories and their clones
# side by side, a modelled release key (certify-only primary, signing subkey)
# whose public half is every repository's KEYS, and PATH shims for gh, cosign,
# gpg-connect-agent, curl and bump-deps. git and gpg are real: the tags the
# train signs are real signed tags, judged by the real verify-release-tag.sh,
# pushed to the fake remotes. The gh shim models GitHub from those remotes: a
# CI run exists for every pushed commit, a release run and a release exist
# for every pushed tag, a rehearsal run for every dispatch; each can be made
# red per repository. The answers to the train's questions come from a file.
#
# The world lives under /var/tmp/ci-kapije/rt-selftest-* when that directory
# exists (the maintainer machine: /tmp is RAM there), else under $TMPDIR.
set -u

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/release-train"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }
for t in git gpg python3; do command -v "$t" >/dev/null 2>&1 || { echo "$t is not on PATH -- cannot run" >&2; exit 2; }; done
# Never $TMPDIR: on macOS it is a long /var/folders path, and the gpg-agent
# sockets under each GNUPGHOME here would pass the 104-byte socket limit.
base=/var/tmp/ci-kapije; [ -d "$base" ] && [ -w "$base" ] || base=/var/tmp
top="$(mktemp -d "$base/rt-selftest-XXXXXX")" || exit 2
cleanup() {
    local d
    for d in "$top"/*/gnupg; do GNUPGHOME="$d" gpgconf --kill all >/dev/null 2>&1 || true; done
    rm -rf "$top"
}
trap cleanup EXIT
export GIT_CONFIG_NOSYSTEM=1
V=5.0.0
CODE=(LibreMiddleware LibreAgent LibreLinux LibreDarwin LibreCelik LibreKDE LibreMac)
SITE=LibreSCRS.github.io

cases=0; red=0; fails=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; [ -f "${2:-/dev/null}" ] && tail -n 25 "$2" | sed 's/^/  | /'; fails=$((fails + 1)); }

# ----------------------------------------------------------------- shims --
shims="$top/shims"; mkdir -p "$shims"
cat > "$shims/gh" <<'PY'
#!/usr/bin/env python3
# A model of the GitHub the train talks to, built from the fake remotes.
import hashlib, json, os, subprocess, sys
S = os.environ["STUB_STATE"]; R = os.environ["STUB_REMOTES"]
def lst(name): return [x for x in os.environ.get(name, "").split(",") if x]
def git(repo, *a):
    return subprocess.run(["git", "--git-dir", f"{R}/{repo}.git", *a], capture_output=True, text=True)
def load():
    p = f"{S}/runs.json"
    return json.load(open(p)) if os.path.exists(p) else []
def save(runs): json.dump(runs, open(f"{S}/runs.json", "w"))
def opt(args, name, default=None):
    return args[args.index(name) + 1] if name in args else default
def repo_of(args): return (opt(args, "-R") or opt(args, "--repo")).split("/", 1)[1]
def sha256(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()
def log(line):
    with open(f"{S}/gh.log", "a") as f: f.write(line + "\n")
def new_run(runs, **kw):
    kw["databaseId"] = 1000 + len(runs); kw["status"] = "completed"; runs.append(kw); return kw
def tags_at(repo, sha):
    return git(repo, "tag", "--points-at", sha).stdout.split()
def assets(repo, tag):
    d = f"{S}/releases/{repo}/{tag}"
    if os.path.isdir(d): return d
    os.makedirs(d)
    decl = git(repo, "show", f"{tag}:ci/release-assets.txt").stdout
    if ".orig.tar.gz" in decl:
        f = f"{d}/{repo.lower()}_{tag}.orig.tar.gz"; open(f, "w").write(f"source of {repo} {tag}\n")
        with open(f"{d}/SHA256SUMS", "w") as s: s.write(f"{sha256(f)}  {os.path.basename(f)}\n")
        ref = "refs/heads/main" if repo in lst("STUB_BAD_SIGNER") else f"refs/tags/{tag}"
        who = f"https://github.com/LibreSCRS/{repo}/.github/workflows/release.yml@{ref}"
        for x in (f, f"{d}/SHA256SUMS"):
            open(x + ".sigstore.json", "w").write(
                f"sha={sha256(x)}\nsigner={who}\nissuer=https://token.actions.githubusercontent.com\n")
    return d
a = sys.argv[1:]
cmd = " ".join(a[:2])
log(" ".join(a))
if cmd == "auth status":
    sys.exit(1 if os.environ.get("STUB_GH_UNAUTH") else 0)
if cmd == "run list":
    repo = repo_of(a); wf = opt(a, "--workflow"); sha = opt(a, "--commit"); ev = opt(a, "--event")
    runs = load()
    if wf in ("ci.yml", "deploy.yml") and git(repo, "cat-file", "-e", f"{sha}^{{commit}}").returncode == 0:
        if not any(r["repo"] == repo and r["wf"] == wf and r["sha"] == sha for r in runs):
            new_run(runs, repo=repo, wf=wf, sha=sha, event="push",
                    conclusion="failure" if repo in lst("STUB_CI_RED") else "success")
    if wf == "release.yml" and ev == "push":
        for t in tags_at(repo, sha):
            if not any(r["repo"] == repo and r["wf"] == wf and r.get("tag") == t for r in runs):
                new_run(runs, repo=repo, wf=wf, sha=sha, event="push", tag=t,
                        conclusion="failure" if repo in lst("STUB_RELEASE_RED") else "success")
    save(runs)
    out = [r for r in reversed(runs) if r["repo"] == repo and r["wf"] == wf and r["sha"] == sha
           and (ev is None or r["event"] == ev)]
    print(json.dumps([{k: r[k] for k in ("databaseId", "status", "conclusion")} for r in out]))
    sys.exit(0)
if cmd == "run watch":
    rid = int(a[2]); runs = load()
    r = [x for x in runs if x["databaseId"] == rid]
    sys.exit(0 if r and r[0]["conclusion"] == "success" else 1)
if cmd == "workflow run":
    repo = repo_of(a); runs = load()
    sha = git(repo, "rev-parse", "refs/heads/main").stdout.strip()
    new_run(runs, repo=repo, wf=a[2], sha=sha, event="workflow_dispatch", mode=opt(a, "-f"),
            conclusion="failure" if repo in lst("STUB_REHEARSE_RED") else "success")
    save(runs); sys.exit(0)
if cmd == "release view":
    repo = repo_of(a); tag = a[2]
    if git(repo, "rev-parse", "-q", "--verify", f"refs/tags/{tag}").returncode != 0: sys.exit(1)
    d = assets(repo, tag)
    print(json.dumps({"isDraft": False, "assets": [{"name": n} for n in sorted(os.listdir(d))]}))
    sys.exit(0)
if cmd == "release download":
    repo = repo_of(a); tag = a[2]; dest = opt(a, "-D")
    if git(repo, "rev-parse", "-q", "--verify", f"refs/tags/{tag}").returncode != 0: sys.exit(1)
    d = assets(repo, tag); names = sorted(os.listdir(d))
    if not names: print("no assets to download", file=sys.stderr); sys.exit(1)
    os.makedirs(dest, exist_ok=True)
    for n in names: open(f"{dest}/{n}", "wb").write(open(f"{d}/{n}", "rb").read())
    sys.exit(0)
if cmd == "attestation verify":
    f = a[2]; r = opt(a, "--repo"); w = opt(a, "--signer-workflow"); ref = opt(a, "--source-ref")
    repo = r.split("/", 1)[1]
    if repo in lst("STUB_ATTEST_RED") or not ref or not ref.startswith("refs/tags/"): sys.exit(1)
    d = f"{S}/releases/{repo}/{ref[len('refs/tags/'):]}"
    if w != f"{r}/.github/workflows/release.yml" or not os.path.exists(f"{d}/SHA256SUMS"): sys.exit(1)
    sys.exit(0 if sha256(f) in open(f"{d}/SHA256SUMS").read() else 1)
print("gh shim: not modelled: " + " ".join(a), file=sys.stderr); sys.exit(3)
PY
cat > "$shims/cosign" <<'SH'
#!/usr/bin/env bash
dig() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
[ "$1" = verify-blob ] || { echo "cosign shim: $1 not modelled" >&2; exit 3; }
shift; bundle="" file="" id="" iss=""
while [ "$#" -gt 0 ]; do
  case "$1" in --bundle) bundle=$2; shift ;; --certificate-identity) id=$2; shift ;;
    --certificate-oidc-issuer) iss=$2; shift ;; *) file=$1 ;; esac; shift
done
[ -f "$bundle" ] && [ "$(sed -n 's/^sha=//p' "$bundle")" = "$(dig "$file")" ] || exit 1
[ "$(sed -n 's/^issuer=//p' "$bundle")" = "$iss" ] && [ "$(sed -n 's/^signer=//p' "$bundle")" = "$id" ]
SH
cat > "$shims/gpg-connect-agent" <<'SH'
#!/usr/bin/env bash
c=1; [ -n "${STUB_NOT_CACHED:-}" ] && c=-
printf 'S KEYINFO %s D - - %s P - - -\nOK\n' "$STUB_GRIP" "$c"
SH
cat > "$shims/curl" <<'SH'
#!/usr/bin/env bash
# The page is whatever the site's origin main publishes: the ref in its data.
url="${*: -1}"
ref=$(git --git-dir="$STUB_REMOTES/LibreSCRS.github.io.git" show main:data/artifacts.json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ref",""))' 2>/dev/null)
[ -n "${STUB_SITE_STALE:-}" ] && ref=4.2.0
printf '<html>%s downloads for %s</html>\n' "$url" "$ref"
SH
cat > "$shims/bump-deps" <<'SH'
#!/usr/bin/env bash
# A model of bump-deps: behind counts from a state file, to-head commits.
set -u
declare -A EXPECT=([LibreAgent]="LibreMiddleware" [LibreLinux]="LibreMiddleware LibreAgent"
  [LibreDarwin]="LibreMiddleware LibreAgent" [LibreCelik]="LibreAgent" [LibreKDE]="LibreAgent" [LibreMac]="LibreAgent")
cmd=$1; shift; ws=""; root=""; tag=""; repos=()
while [ "$#" -gt 0 ]; do
  case "$1" in --workspace) ws=$2; shift ;; --root) root=$2; shift ;; --tag) tag=$2; shift ;; *) repos+=("$1") ;; esac; shift
done
echo "$cmd ${repos[*]} root=$root tag=$tag" >> "$STUB_STATE/bump.log"
behind() { awk -v c="$1" -v d="$2" '$1==c && $2==d {n=$3} END {print n+0}' "$STUB_STATE/behind" 2>/dev/null || echo 0; }
[ "${#repos[@]}" -gt 0 ] || repos=(LibreMiddleware LibreAgent LibreLinux LibreDarwin LibreCelik LibreKDE LibreMac)
case "$cmd" in
  status)
    echo "consumer dep locked upstream behind source product-paths"
    for c in "${repos[@]}"; do for d in ${EXPECT[$c]:-}; do echo "$c $d aaaa bbbb $(behind "$c" "$d") deps.lock -"; done; done ;;
  to-head)
    for c in "${repos[@]}"; do
      for d in ${EXPECT[$c]:-}; do
        [ "$(behind "$c" "$d")" -gt 0 ] || continue
        echo "$d $(git --git-dir="$STUB_REMOTES/$d.git" rev-parse main)" >> "$ws/$c/deps.lock"
        git -C "$ws/$c" commit -q -m "build: track $d" -- deps.lock
        grep -v "^$c $d " "$STUB_STATE/behind" > "$STUB_STATE/behind.new"; mv "$STUB_STATE/behind.new" "$STUB_STATE/behind"
      done
    done ;;
  check)
    if [ -n "$root" ]; then
      case ",${STUB_TAGCHECK_RED:-}," in *",$(basename "$root"),"*) exit 1 ;; esac; exit 0
    fi
    exit "${STUB_BUMP_CHECK_RC:-0}" ;;
esac
SH
chmod 755 "$shims"/*

# ----------------------------------------------------------------- world --
# The release key, modelled once and copied into each world.
keys="$top/keys"; mkdir -m 700 "$keys"
G() { GNUPGHOME="$1" gpg --batch --quiet --pinentry-mode loopback --passphrase '' "${@:2}"; }
G "$keys" --quick-gen-key "Selftest Release <release@invalid>" ed25519 cert 3y >/dev/null 2>&1 || exit 2
PFPR="$(G "$keys" --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')"
G "$keys" --quick-add-key "$PFPR" ed25519 sign 2y >/dev/null 2>&1 || exit 2
GNUPGHOME="$keys" gpgconf --kill all >/dev/null 2>&1

world() {  # world <name>: a fresh world; sets W and the environment for it
    W="$top/$1"; mkdir -p "$W/remotes" "$W/root" "$W/state"
    cp -a "$keys" "$W/gnupg"
    export GNUPGHOME="$W/gnupg"
    GRIP="$(gpg --batch --with-colons --with-keygrip --list-secret-keys "$PFPR" 2>/dev/null \
            | awk -F: '$1=="ssb"{s=1} s && $1=="grp"{print $10; exit}')"
    gpg --batch --armor --export "$PFPR" > "$W/KEYS" 2>/dev/null
    printf '[user]\n\tname = t\n\temail = t@invalid\n[commit]\n\tgpgSign = false\n[tag]\n\tgpgSign = false\n[init]\n\tdefaultBranch = main\n' > "$W/gitconfig"
    export GIT_CONFIG_GLOBAL="$W/gitconfig"
    local r d
    for r in "${CODE[@]}" "$SITE"; do
        git init -q --bare "$W/remotes/$r.git"
        d="$W/root/$r"; git init -q "$d"
        if [ "$r" = "$SITE" ]; then
            mkdir -p "$d/tools" "$d/content/downloads" "$d/data"
            printf 'downloads\n' > "$d/content/downloads/_index.md"
            printf '{"ref": "HEAD", "provisional": true}\n' > "$d/data/artifacts.json"
            cat > "$d/tools/gen-artifacts-data.py" <<'PYG'
import json, sys
ref = sys.argv[sys.argv.index("--ref") + 1]
json.dump({"ref": ref, "provisional": False}, open("data/artifacts.json", "w"))
PYG
            printf 'import os, sys\nsys.exit(1 if os.environ.get("STUB_CLAIMS_RED") else 0)\n' > "$d/tools/check_download_claims.py"
        else
            printf '%s\n' "$V" > "$d/VERSION"
            printf '# Changelog\n\n## [Unreleased] — %s\n\n- an entry\n\n## [4.2.0]\n\n- older\n' "$V" > "$d/CHANGELOG.md"
            cp "$W/KEYS" "$d/KEYS"; mkdir -p "$d/ci"
            case "$r" in
                LibreDarwin|LibreMac) printf '# notes only\n' > "$d/ci/release-assets.txt" ;;
                *) printf '*.orig.tar.gz  source\nSHA256SUMS  sums\n*.sigstore.json  bundles\n' > "$d/ci/release-assets.txt" ;;
            esac
            printf '# deps\n' > "$d/deps.lock"
        fi
        git -C "$d" add -A && git -C "$d" commit -q -m "initial $r"
        git -C "$d" remote add origin "$W/remotes/$r.git"
        git -C "$d" push -q origin main
    done
    : > "$W/answers"
    export STUB_STATE="$W/state" STUB_REMOTES="$W/remotes" STUB_GRIP="$GRIP"
}
train() {  # train <args...>: the subject in the current world; output to $W/out
    env PATH="$shims:$PATH" BUMP_DEPS="$shims/bump-deps" EXPECTED_FPR="$PFPR" \
        RELEASE_TRAIN_TTY="$W/answers" RELEASE_TRAIN_POLL=0 RELEASE_TRAIN_WAIT=0 \
        SITE_URL_EN=https://site/downloads/ SITE_URL_SR=https://site/sr/downloads/ \
        bash "$subject" "$V" --root "$W/root" "$@" > "$W/out" 2>&1 < /dev/null
}
answers() { printf '%s\n' "$@" > "$W/answers"; }
expect_rc() {  # expect_rc <name> <want> <got> [needle]
    cases=$((cases + 1)); [ "$2" != 0 ] && red=$((red + 1))
    if [ "$3" != "$2" ]; then fail "$1: rc=$3, want $2" "$W/out"; return 1; fi
    if [ -n "${4:-}" ] && ! grep -qF -- "$4" "$W/out"; then fail "$1: rc=$3 as wanted, but no '$4'" "$W/out"; return 1; fi
    pass "$1 (rc=$3)"
}
assert() {  # assert <name> <command...>: a property of the world after a run
    local name=$1; shift
    cases=$((cases + 1))
    if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "$W/out"; fi
}
remote_has_tag() { git --git-dir="$W/remotes/$1.git" rev-parse -q --verify "refs/tags/$V" >/dev/null; }
no_remote_tags() { local r; for r in "${CODE[@]}"; do remote_has_tag "$r" && return 1; done; return 0; }
all_remote_tags() { local r; for r in "${CODE[@]}"; do remote_has_tag "$r" || return 1; done; return 0; }
dispatches() { grep -c '^workflow run release.yml' "$W/state/gh.log" 2>/dev/null || true; }
yes7() { answers yes yes yes yes yes yes yes yes; }

# ------------------------------------------------------------------ cases --
# T1 -- the whole train over a world that needs no lock: five tag layers and
# the site, six questions, every tag signed, pushed, released and verified.
world t1; yes7; train; rc=$?
expect_rc "T1 the whole train" 0 "$rc" "released in 7 repositories and on the site"
assert "T1 every code repository's origin carries the signed tag" all_remote_tags
assert "T1 seven rehearsals were dispatched, all mode=rehearse" \
    test "$(grep -c '^workflow run release.yml .*-f mode=rehearse' "$W/state/gh.log")" = 7
assert "T1 exactly six questions were asked (5 tag layers + site)" test "$(grep -c '^ask - yes' "$W/root/release-train-$V.ledger")" = 6
assert "T1 the site's origin publishes the release's data" \
    bash -c 'git --git-dir="$1" show main:data/artifacts.json | grep -q "\"ref\": \"$2\""' _ "$W/remotes/$SITE.git" "$V"
assert "T1 the tag object on origin verifies against KEYS" \
    env REPO_ROOT="$W/root/LibreAgent" EXPECTED_FPR="$PFPR" bash "$here/verify-release-tag.sh" tag "$V"

# T2 -- --rehearse-only: every rehearsal, no question, nothing pushed.
world t2; : > "$W/answers"; train --rehearse-only; rc=$?
expect_rc "T2 rehearse-only" 0 "$rc" "nothing was pushed"
assert "T2 no tag reached any origin" no_remote_tags
assert "T2 seven rehearsals dispatched" test "$(dispatches)" = 7

# T3-T8 -- the preflight refuses, and nothing moves.
world t3; echo dirt > "$W/root/LibreKDE/untracked"; yes7; train; rc=$?
expect_rc "T3 a dirty clone" 1 "$rc" "LibreKDE: the working tree is not clean"
assert "T3 nothing dispatched, nothing tagged" bash -c '[ "$(grep -c "^workflow run" "$1" 2>/dev/null || true)" = 0 ]' _ "$W/state/gh.log"
world t4; git -C "$W/root/LibreLinux" commit -q --allow-empty -m local; yes7; train; rc=$?
expect_rc "T4 a local commit origin does not have" 1 "$rc" "LibreLinux: HEAD"
world t5; yes7; STUB_CI_RED=LibreCelik train; rc=$?
expect_rc "T5 CI red on a HEAD" 1 "$rc" "LibreCelik: ci.yml is not green"
world t6; printf '4.9.9\n' > "$W/root/LibreDarwin/VERSION"
git -C "$W/root/LibreDarwin" commit -q -am "version"; git -C "$W/root/LibreDarwin" push -q origin main
yes7; train; rc=$?
expect_rc "T6 a VERSION that is not the release" 1 "$rc" "LibreDarwin: VERSION or the CHANGELOG section does not say $V"
world t7; git -C "$W/root/LibreMac" tag -a -m x "$V"; git -C "$W/root/LibreMac" push -q origin "refs/tags/$V"
yes7; train; rc=$?
expect_rc "T7 the tag already exists on origin" 1 "$rc" "LibreMac: tag $V already exists on origin"
world t8; yes7; STUB_NOT_CACHED=1 train; rc=$?
expect_rc "T8 the signing key is not unlocked in the agent" 1 "$rc" "is not unlocked in gpg-agent"
world t8b; gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-set-expire "$PFPR" 30d '*' >/dev/null 2>&1
yes7; train; rc=$?
expect_rc "T8b a signing subkey that expires within six months" 1 "$rc" "expires in less than six months"
world t9; yes7; STUB_GH_UNAUTH=1 train; rc=$?
expect_rc "T9 gh not authenticated is cannot-judge" 2 "$rc" "gh is not authenticated"
world t10; yes7; STUB_BUMP_CHECK_RC=1 train; rc=$?
expect_rc "T10 bump-deps check red" 1 "$rc" "bump-deps check is not green"

# T11 -- a lock is behind: layer 2 is bumped, shown, asked, pushed and CI
# waited for; the rest of the train then runs on the new mains.
world t11; printf 'LibreAgent LibreMiddleware 3\n' > "$W/state/behind"
answers yes yes yes yes yes yes yes; train; rc=$?
expect_rc "T11 a behind lock is bumped, confirmed and pushed" 0 "$rc" "LibreAgent: 1 commit(s) on top of origin main"
assert "T11 the bump commit is on LibreAgent's origin main" \
    bash -c 'git --git-dir="$1" log -1 --format=%s main | grep -qx "build: track LibreMiddleware"' _ "$W/remotes/LibreAgent.git"
assert "T11 LibreAgent's tag is on the bump commit" \
    bash -c '[ "$(git --git-dir="$1" rev-parse "$2^{commit}")" = "$(git --git-dir="$1" rev-parse main)" ]' _ "$W/remotes/LibreAgent.git" "$V"

# T12 -- a lock is behind and the answer is no: nothing is pushed.
world t12; printf 'LibreAgent LibreMiddleware 3\n' > "$W/state/behind"; answers no; train; rc=$?
expect_rc "T12 declining the lock push" 1 "$rc" "not confirmed -- nothing pushed"
assert "T12 LibreAgent's origin main did not move" \
    bash -c '[ "$(git --git-dir="$1" log -1 --format=%s main)" = "initial LibreAgent" ]' _ "$W/remotes/LibreAgent.git"

# T13/T14 -- declining the first tag layer leaves origin untagged; --resume
# then reuses the local tag (the same object) and finishes.
world t13; answers no; train; rc=$?
expect_rc "T13 declining the first tag layer" 1 "$rc" "not confirmed"
assert "T13 no tag on any origin" no_remote_tags
obj="$(git -C "$W/root/LibreMiddleware" rev-parse "refs/tags/$V")"
yes7; train --resume; rc=$?
expect_rc "T14 --resume finishes the train" 0 "$rc" "reusing the local tag $V"
assert "T14 the resumed train pushed the same tag object" \
    test "$(git --git-dir="$W/remotes/LibreMiddleware.git" rev-parse "refs/tags/$V")" = "$obj"
assert "T14 the rehearsals were not dispatched twice" test "$(dispatches)" = 7

# T15 -- a rehearsal is red: no tag anywhere.
world t15; yes7; STUB_REHEARSE_RED=LibreCelik train; rc=$?
expect_rc "T15 a red rehearsal stops the train before any tag" 1 "$rc" "LibreCelik: rehearsal run"
assert "T15 no tag on any origin" no_remote_tags

# T16 -- a red release run: the layers before it are released, the rest not.
world t16; yes7; STUB_RELEASE_RED=LibreAgent train; rc=$?
expect_rc "T16 a red release run stops at its layer" 1 "$rc" "LibreAgent: release run"
assert "T16 LibreMiddleware released, LibreLinux not tagged" \
    bash -c 'grep -q "^verified LibreMiddleware done" "$1" && ! git --git-dir="$2" rev-parse -q --verify "refs/tags/$3" >/dev/null' \
    _ "$W/root/release-train-$V.ledger" "$W/remotes/LibreLinux.git" "$V"

# T17/T18 -- the downloaded release does not verify.
world t17; yes7; STUB_BAD_SIGNER=LibreMiddleware train; rc=$?
expect_rc "T17 a published asset signed from a branch" 1 "$rc" "LibreMiddleware: the downloaded release $V does not verify"
world t18; yes7; STUB_ATTEST_RED=LibreKDE train; rc=$?
expect_rc "T18 a published asset without provenance" 1 "$rc" "LibreKDE: the downloaded release $V does not verify"

# T19 -- a local tag signed by another key is refused before it is pushed.
world t19; mkdir -m 700 "$W/forger"
GNUPGHOME="$W/forger" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Forger <f@invalid>" ed25519 sign 1d >/dev/null 2>&1
ffpr="$(GNUPGHOME="$W/forger" gpg --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
GNUPGHOME="$W/forger" git -C "$W/root/LibreMiddleware" tag -s -u "$ffpr" -m forged "$V" >/dev/null 2>&1
GNUPGHOME="$W/forger" gpgconf --kill all >/dev/null 2>&1
yes7; train; rc=$?
expect_rc "T19 a local tag by another key" 1 "$rc" "does not pass the release workflow's signature check"
assert "T19 it never reached origin" bash -c '! git --git-dir="$1" rev-parse -q --verify "refs/tags/$2" >/dev/null' _ "$W/remotes/LibreMiddleware.git" "$V"

# T20 -- main moved after the freeze: --resume refuses.
world t20; answers no; train
git -C "$W/root/LibreKDE" commit -q --allow-empty -m "late"; git -C "$W/root/LibreKDE" push -q origin main
yes7; train --resume; rc=$?
expect_rc "T20 --resume after main moved past the freeze" 1 "$rc" "LibreKDE: main moved after the freeze"

# T21 -- a ledger without --resume is refused, and a foreign ledger with it.
world t21; printf 'train %s started\n' "$V" > "$W/root/release-train-$V.ledger"; train; rc=$?
expect_rc "T21 an existing ledger without --resume" 2 "$rc" "already ran"
printf 'train 9.9.9 started\n' > "$W/root/release-train-$V.ledger"; train --resume; rc=$?
expect_rc "T21b a ledger of another release" 2 "$rc" "is not a ledger of release $V"

# T22 -- the site does not name the release after its deploy.
world t22; yes7; STUB_SITE_STALE=1 train; rc=$?
expect_rc "T22 a download page that does not name the release" 1 "$rc" "does not name $V yet"
world t22b; yes7; STUB_CLAIMS_RED=1 train; rc=$?
expect_rc "T22b download claims red before the site push" 1 "$rc" "do not match release $V"
assert "T22b the site's origin was not pushed" \
    bash -c '[ "$(git --git-dir="$1" log -1 --format=%s main)" = "initial LibreSCRS.github.io" ]' _ "$W/remotes/$SITE.git"

# T23 -- --prepare renames the CHANGELOG heading in all seven, one question per
# layer, and the tags land on those commits.
world t23; answers yes yes yes yes yes yes yes yes yes yes yes; train --prepare; rc=$?
expect_rc "T23 --prepare" 0 "$rc" "released in 7 repositories"
assert "T23 every origin CHANGELOG now heads [$V] — <date>" bash -c '
    for r in LibreMiddleware LibreAgent LibreLinux LibreDarwin LibreCelik LibreKDE LibreMac; do
        git --git-dir="$1/$r.git" show "$2:CHANGELOG.md" | grep -q "^## \[$2\] — [0-9-]*\$" || exit 1
    done' _ "$W/remotes" "$V"

# T24 -- the consumer's locks do not name the upstream tags at tag time.
world t24; yes7; STUB_TAGCHECK_RED=LibreLinux train; rc=$?
expect_rc "T24 bump-deps check --tag red for a consumer" 1 "$rc" "LibreLinux: bump-deps check --tag $V is not green"

# T25-T27 -- usage and cannot-judge.
world t25; train --rehearse-only --prepare; rc=$?
expect_rc "T25 --prepare with --rehearse-only" 2 "$rc" "cannot be combined"
env PATH="$shims:$PATH" BUMP_DEPS="$W/no-bump-deps" bash "$subject" "$V" --root "$W/root" > "$W/out" 2>&1; rc=$?
expect_rc "T26 no bump-deps" 2 "$rc" "no bump-deps"
bash "$subject" 5.0 --root "$W/root" > "$W/out" 2>&1; rc=$?
expect_rc "T27 not a version" 2 "$rc" "is not a version"

# P1/P2 -- perturbations of the train itself, each proving that a case above
# discriminates: with the question answered by the script, the declined train
# of T13 pushes its tags; without the local signature check, T19's forged tag
# reaches origin. The perturbed copy sits beside the real one so it finds the
# same helpers.
perturbed="$here/.release-train.perturbed.$$"
trap 'rm -f "$perturbed"; cleanup' EXIT
perturb() {  # perturb <old> <new>: the train with one literal clause replaced
    python3 - "$subject" "$perturbed" "$1" "$2" <<'PYP'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if old not in t:
    sys.exit(1)
open(dst, "w").write(t.replace(old, new))
PYP
}
if perturb '    if [ "$answer" != yes ]; then' '    if false; then'; then
    world p1; answers no; subject_real=$subject; subject=$perturbed; train; subject=$subject_real
    cases=$((cases + 1)); red=$((red + 1))
    if all_remote_tags; then pass "P1 a train that answers itself pushes what T13 declined -- T13 discriminates"
    else fail "P1 the self-answering train did not push -- T13 proves nothing" "$W/out"; fi
else
    cases=$((cases + 1)); fail "P1 the clause to perturb is not in the train"
fi
if perturb '        EXPECTED_FPR="$EXPECTED_FPR" REPO_ROOT="$ROOT/$r" bash "$here/verify-release-tag.sh" tag "$V" \' '        true \'; then
    world p2; mkdir -m 700 "$W/forger"
    GNUPGHOME="$W/forger" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
        --quick-gen-key "Forger <f@invalid>" ed25519 sign 1d >/dev/null 2>&1
    ffpr="$(GNUPGHOME="$W/forger" gpg --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
    GNUPGHOME="$W/forger" git -C "$W/root/LibreMiddleware" tag -s -u "$ffpr" -m forged "$V" >/dev/null 2>&1
    GNUPGHOME="$W/forger" gpgconf --kill all >/dev/null 2>&1
    yes7; subject_real=$subject; subject=$perturbed; train; subject=$subject_real
    cases=$((cases + 1)); red=$((red + 1))
    if remote_has_tag LibreMiddleware; then pass "P2 without the local check the forged tag reaches origin -- T19 discriminates"
    else fail "P2 the forged tag did not reach origin without the check -- T19 proves nothing" "$W/out"; fi
else
    cases=$((cases + 1)); fail "P2 the clause to perturb is not in the train"
fi
rm -f "$perturbed"

if [ "$fails" -eq 0 ]; then
    echo "release-train selftest: all cases passed"
else
    echo "release-train selftest: $fails case(s) failed"
fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fails" -eq 0 ]
