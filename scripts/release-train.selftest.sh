#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC2016  # fixture and perturbation text is literal on purpose
# Self-test for release-train, over fake remotes.
#
# Each case builds a world: eight bare "origin" repositories and their clones
# side by side, a modelled release key (certify-only primary, signing subkey)
# whose public half is every repository's KEYS, and PATH shims for gh, cosign,
# gpg-connect-agent and curl -- the network services, none of them on the pin
# path. git, gpg and bump-deps are real: the deps.lock files are written by the
# real `bump-deps to-head` (once, into a template every world copies) and every
# lock, freeze and `check --tag` the train runs is the real tool over the fake
# remotes; the tags the train signs are real signed tags, judged by the real
# verify-release-tag.sh, pushed to the fake remotes. The gh shim models GitHub from those remotes: a
# CI run exists for every pushed commit, a release run and a release exist
# for every pushed tag, a rehearsal run for every dispatch; each can be made
# red per repository. The answers to the train's questions come from a file.
#
# The ninth clone, packages, is modelled too (its KEYS). The package
# certificate, beside its env as in keys/, is the repository's rehearsal key
# set (keys/rehearsal.*) certified here by the modelled release key, and the published package repository is a set of trees signed here with
# that key set's subkeys -- the generation a publish leaves, the one before it,
# and the broken ones -- which the curl shim serves for PACKAGES_URL. gpgv, xz
# and zstd are real. pkg-repo.py watch is a shim here: its own self-test is
# pkg-repo.selftest.py. The LibreSCRS/ci the repositories pin is a clone of
# its own (RELEASE_TRAIN_CI) whose commits carry keys/: one with this package
# key set, one with the other one, one with a certificate that is not it.
#
# The world lives under /var/tmp/ci-kapije/rt-selftest-* when that directory
# exists (the maintainer machine: /tmp is RAM there), else under /var/tmp.
set -u

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/release-train"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }
for t in git gpg gpgv xz zstd python3; do command -v "$t" >/dev/null 2>&1 || { echo "$t is not on PATH -- cannot run" >&2; exit 2; }; done
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
def move(repo, msg):  # somebody else lands a commit on origin main
    tree = git(repo, "rev-parse", "main^{tree}").stdout.strip()
    new = git(repo, "commit-tree", tree, "-p", "main", "-m", msg).stdout.strip()
    git(repo, "update-ref", "refs/heads/main", new)
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
    # Like gh: any broken stored account fails it, even with a good active one.
    sys.exit(1 if os.environ.get("STUB_GH_UNAUTH") or os.environ.get("STUB_GH_OTHER_BROKEN") else 0)
if cmd == "api user":
    if os.environ.get("STUB_GH_UNAUTH"):
        sys.exit(1)
    print("stub-user"); sys.exit(0)
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
    if (r and r[0]["wf"] == "release.yml" and r[0]["event"] == "push" and os.environ.get("STUB_MOVE_PACKAGES")
            and not os.path.exists(f"{S}/moved")):
        open(f"{S}/moved", "w").close(); move("packages", "landed while the tags were out")
    sys.exit(0 if r and r[0]["conclusion"] == "success" else 1)
if cmd == "workflow run":
    repo = repo_of(a); runs = load()
    sha = git(repo, "rev-parse", "refs/heads/main").stdout.strip()
    new_run(runs, repo=repo, wf=a[2], sha=sha, event="workflow_dispatch", mode=opt(a, "-f"),
            conclusion="failure" if repo in lst("STUB_REHEARSE_RED")
            or (a[2] == "publish.yml" and "mode=publish" in a and os.environ.get("STUB_PUBLISH_RED")) else "success")
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
url="${*: -1}" out=""
while [ "$#" -gt 1 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
echo "$url" >> "$STUB_STATE/curl.log"
# The package repository: one generation per look, a look starting at the
# trixie InRelease; the first STUB_REPO_STALE looks see the previous one.
case "$url" in
    https://pkgs/packages/*)
        rel=${url#https://pkgs/packages/} cnt="$STUB_STATE/inrelease.n"
        [ "$rel" != deb/dists/trixie/InRelease ] || echo $(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 )) > "$cnt"
        gen="$STUB_REPOS/${STUB_REPO:-new}"
        [ "$(cat "$cnt" 2>/dev/null || echo 0)" -gt "${STUB_REPO_STALE:-0}" ] || gen="$STUB_REPOS/old"
        [ -f "$gen/$rel" ] || exit 22
        if [ -n "$out" ]; then cat "$gen/$rel" > "$out"; else cat "$gen/$rel"; fi
        exit 0 ;;
esac
# The page is whatever the site's origin main publishes: the ref in its data.
ref=$(git --git-dir="$STUB_REMOTES/LibreSCRS.github.io.git" show main:data/artifacts.json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ref",""))' 2>/dev/null)
n=$(( $(cat "$STUB_STATE/site.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_STATE/site.n"
[ "$n" -gt "${STUB_SITE_STALE:-0}" ] || ref=4.2.0
printf '<html>%s downloads for %s</html>\n' "$url" "$ref"
SH
cat > "$shims/pkg-repo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_STATE/pkg-repo.log"
# STUB_WATCH_404: nothing deployed, while a code repository has released
if [ -n "${STUB_WATCH_404:-}" ]; then
    echo "::error::https://pkgs/packages/deb/dists/trixie/InRelease is HTTP 404, but LibreMiddleware released -- the published repository is gone"
    exit 1
fi
[ "${STUB_WATCH_RC:-0}" = 0 ] || echo "::error::deb/dists/trixie/InRelease: Valid-Until is less than 14 days away"
exit "${STUB_WATCH_RC:-0}"
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

# The package key set: the repository's rehearsal keys, its certificate
# certified by the release key (in a copy of the release key's home), and the
# published trees signed with its subkeys in a home of their own.
kdir="$here/../keys"
pkgkey="$top/pkgkey"; mkdir -m 700 "$pkgkey"
G "$pkgkey" --import "$kdir/rehearsal.sec.asc" >/dev/null 2>&1 || exit 2
cp "$kdir/rehearsal.env" "$top/package-signing.env"
PKFPR="$(sed -n 's/^PACKAGE_FPR=//p' "$top/package-signing.env")"
S_IDX="$(sed -n 's/^S_IDX_FPR=//p' "$top/package-signing.env")"
S_RPM="$(sed -n 's/^S_RPM_FPR=//p' "$top/package-signing.env")"
cp -a "$keys" "$top/certhome"
G "$top/certhome" --import "$kdir/rehearsal.asc" >/dev/null 2>&1 \
    && G "$top/certhome" --local-user "$PFPR" --quick-sign-key "$PKFPR" >/dev/null 2>&1 \
    && G "$top/certhome" --armor --export "$PKFPR" > "$top/package-signing.asc" || exit 2
# A second package key the release key certifies, beside the first: its env
# names the right index subkey under the wrong primary.
G "$top/certhome" --quick-gen-key "Other package key <o@invalid>" ed25519 cert 1y >/dev/null 2>&1 || exit 2
OFPR="$(G "$top/certhome" --with-colons --list-keys "Other package key" | awk -F: '$1=="fpr"{print $10; exit}')"
G "$top/certhome" --local-user "$PFPR" --quick-sign-key "$OFPR" >/dev/null 2>&1 \
    && G "$top/certhome" --armor --export "$PKFPR" "$OFPR" > "$top/KEY-two.asc" || exit 2
sed "s/^PACKAGE_FPR=.*/PACKAGE_FPR=$OFPR/" "$top/package-signing.env" > "$top/package-signing-other.env"
cp "$top/KEY-two.asc" "$top/package-signing-other.asc"
# The release key withdraws its certification.
G "$top/certhome" --quick-revoke-sig "$PKFPR" "$PFPR" >/dev/null 2>&1 \
    && G "$top/certhome" --armor --export "$PKFPR" > "$top/KEY-revoked.asc" || exit 2
GNUPGHOME="$top/certhome" gpgconf --kill all >/dev/null 2>&1; rm -rf "$top/certhome"
cp "$kdir/rehearsal.asc" "$top/KEY-uncertified.asc"
cat > "$top/mkrepo.py" <<'PY'
# mkrepo.py <dir> <librecelik deb version> <librecelik rpm version> <InRelease signer> [stale]
# One published generation; "stale" leaves the by-name Packages.xz of the
# generation before (what a CDN may still serve), by-hash is this one's.
import hashlib, lzma, os, subprocess, sys
d, debv, rpmv, signer = sys.argv[1:5]
stale = sys.argv[5:] == ["stale"]
home, sidx = os.environ["PKGKEY"], os.environ["S_IDX"]
sha = lambda b: hashlib.sha256(b).hexdigest()
def w(rel, data):
    os.makedirs(os.path.dirname(os.path.join(d, rel)) or d, exist_ok=True)
    open(os.path.join(d, rel), "wb").write(data if isinstance(data, bytes) else data.encode())
def sign(rel, out, how, fpr):
    subprocess.run(["gpg", "--batch", "--yes", "--quiet", "--pinentry-mode", "loopback", "--passphrase", "",
                    "--local-user", fpr + "!", "--digest-algo", "SHA512"] + how
                   + ["--output", os.path.join(d, out), os.path.join(d, rel)],
                   env=dict(os.environ, GNUPGHOME=home), check=True, capture_output=True)
def packages(v):  # another package carries the release's revision in every generation
    return (f"Package: librescrs-agent\nVersion: 5.0.0-1~deb13\nArchitecture: amd64\n\n"
            f"Package: librecelik\nVersion: {v}\nArchitecture: amd64\nFilename: pool/trixie/librecelik_{v}_amd64.deb\n").encode()
base = "deb/dists/trixie"
pk = packages(debv)
xz = lzma.compress(pk)
ents = []
for n, data in (("Packages", pk), ("Packages.xz", xz)):
    w(f"{base}/main/binary-amd64/by-hash/SHA256/{sha(data)}", data)
    ents.append(f" {sha(data)} {len(data):>10} main/binary-amd64/{n}")
w(f"{base}/main/binary-amd64/Packages", pk)
w(f"{base}/main/binary-amd64/Packages.xz", lzma.compress(packages("4.2.0-1~deb13")) if stale else xz)
w(f"{base}/Release", "Origin: LibreSCRS\nSuite: trixie\nCodename: trixie\n"
  "Valid-Until: Sat, 01 Jan 2050 00:00:00 +0000\nAcquire-By-Hash: yes\nSHA256:\n" + "\n".join(ents) + "\n")
sign(f"{base}/Release", f"{base}/InRelease", ["--clearsign"], signer)
prim = (f'<?xml version="1.0"?><metadata xmlns="http://linux.duke.edu/metadata/common" packages="1">'
        f'<package type="rpm"><name>librecelik</name><arch>x86_64</arch>'
        f'<version epoch="0" ver="{rpmv}" rel="1.fc44"/></package></metadata>').encode()
z = subprocess.run(["zstd", "-q", "-c"], input=prim, capture_output=True, check=True).stdout
rd = "rpm/fedora44/repodata"
w(f"{rd}/{sha(z)}-primary.xml.zst", z)
w(f"{rd}/repomd.xml", f'<?xml version="1.0"?><repomd xmlns="http://linux.duke.edu/metadata/repo"><revision>1</revision>'
  f'<data type="primary"><checksum type="sha256">{sha(z)}</checksum>'
  f'<location href="repodata/{sha(z)}-primary.xml.zst"/><size>{len(z)}</size></data></repomd>')
sign(f"{rd}/repomd.xml", f"{rd}/repomd.xml.asc", ["--detach-sign", "--armor"], sidx)
w("KEY.asc", open(os.environ["KEY_ASC"], "rb").read())
PY
mkrepo() { PKGKEY="$pkgkey" S_IDX="$S_IDX" KEY_ASC="$top/package-signing.asc" python3 "$top/mkrepo.py" "$top/repos/$1" "${@:2}"; }
if ! { mkrepo new "$V-1~deb13" "$V" "$S_IDX" stale \
        && mkrepo old "4.2.0-1~deb13" 4.2.0 "$S_IDX" \
        && mkrepo rpmsig "$V-1~deb13" "$V" "$S_RPM" \
        && mkrepo badver "$V-1" "$V" "$S_IDX" \
        && mkrepo rpmold "$V-1~deb13" 4.2.0 "$S_IDX"; }; then
    echo "cannot build the package repository fixtures" >&2; exit 2
fi
GNUPGHOME="$pkgkey" gpgconf --kill all >/dev/null 2>&1

# The template every world copies: the eight repositories, locked by the real
# `bump-deps to-head` and pushed. Clones and locks name their origin through
# $top/cur, which world() points at the world in use.
export BUMP_DEPS_URL_BASE="file://$top/cur/remotes"
export GIT_CONFIG_GLOBAL="$top/gitconfig"
printf '[user]\n\tname = t\n\temail = t@invalid\n[commit]\n\tgpgSign = false\n[tag]\n\tgpgSign = false\n[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n' > "$GIT_CONFIG_GLOBAL"
CONTRACT=LibreMacAgentClient/Tests/LibreMacAgentClientTests/Contract
fci="$top/ci"; mkdir -p "$fci/keys"; git init -q "$fci" || exit 2
fake_ci_commit() {  # fake_ci_commit <asc> <env>: a commit of the pinned ci carrying them; prints its SHA
    printf 'keys\n' > "$fci/keys/README.md"
    cp "$1" "$fci/keys/package-signing.asc" && cp "$2" "$fci/keys/package-signing.env" \
        && git -C "$fci" add -A && git -C "$fci" commit -q --allow-empty -m "keys: ${1##*/}" && git -C "$fci" rev-parse HEAD
}
CIPIN="$(fake_ci_commit "$top/package-signing.asc" "$top/package-signing.env")" \
    && CIPIN_OTHER="$(fake_ci_commit "$top/package-signing-other.asc" "$top/package-signing-other.env")" \
    && CIPIN_UNCERT="$(fake_ci_commit "$top/KEY-uncertified.asc" "$top/package-signing.env")" || exit 2
SIGNING=(LibreMiddleware LibreAgent LibreLinux LibreCelik LibreKDE packages)
pin_workflow() {  # pin_workflow <dir> <sha>: the release workflow of a repository that signs packages
    mkdir -p "$1/.github/workflows"
    printf 'jobs:\n  sign:\n    steps:\n      - uses: LibreSCRS/ci/actions/pkg-sign@%s\n' "$2" > "$1/.github/workflows/release.yml"
}
template() {
    local t="$top/template" r d
    mkdir -p "$t/remotes" "$t/root"; ln -sfn "$t" "$top/cur"
    GNUPGHOME="$keys" gpg --batch --armor --export "$PFPR" > "$t/KEYS" 2>/dev/null
    GNUPGHOME="$keys" gpgconf --kill all >/dev/null 2>&1
    for r in "${CODE[@]}" "$SITE" packages; do
        git init -q --bare "$t/remotes/$r.git"
        git -C "$t/remotes/$r.git" config uploadpack.allowFilter true
        git -C "$t/remotes/$r.git" config uploadpack.allowAnySHA1InWant true
        d="$t/root/$r"; git init -q "$d"
        case " ${SIGNING[*]} " in *" $r "*) pin_workflow "$d" "$CIPIN" ;; esac
        if [ "$r" = packages ]; then
            cp "$t/KEYS" "$d/KEYS"
        elif [ "$r" = "$SITE" ]; then
            mkdir -p "$d/tools" "$d/content/downloads" "$d/data"
            printf 'downloads\n' > "$d/content/downloads/_index.md"
            printf '{"ref": "HEAD", "provisional": true}\n' > "$d/data/artifacts.json"
            cat > "$d/tools/gen-artifacts-data.py" <<'PYG'
import json, sys
ref = sys.argv[sys.argv.index("--ref") + 1]
json.dump({"ref": ref, "provisional": False}, open("data/artifacts.json", "w"))
PYG
            # The stub records its arguments and whether --keys named a keys/
            # that exists while it runs (release-train removes it afterwards).
            cat > "$d/tools/check_download_claims.py" <<'PYC'
import os, sys
a = sys.argv[1:]
k = a[a.index("--keys") + 1] if "--keys" in a else ""
seen = "keys-present" if k and os.path.isfile(os.path.join(k, "README.md")) else "keys-absent"
open(os.environ["STUB_STATE"] + "/claims.args", "a").write(" ".join(a) + " " + seen + "\n")
sys.exit(1 if os.environ.get("STUB_CLAIMS_RED") else 0)
PYC
            # The site's ci pin: the pinned ci's commit with keys/.
            mkdir -p "$d/.github/workflows"
            printf 'jobs:\n  build:\n    steps:\n      - uses: LibreSCRS/ci/actions/gates@%s\n' \
                "$CIPIN" > "$d/.github/workflows/deploy.yml"
        else
            printf '%s\n' "$V" > "$d/VERSION"
            printf '# Changelog\n\n## [Unreleased] — %s\n\n- an entry\n\n## [4.2.0]\n\n- older\n' "$V" > "$d/CHANGELOG.md"
            cp "$t/KEYS" "$d/KEYS"; mkdir -p "$d/ci"
            case "$r" in
                LibreDarwin|LibreMac) printf '# notes only\n' > "$d/ci/release-assets.txt" ;;
                *) printf '*.orig.tar.gz  source\nSHA256SUMS  sums\n*.sigstore.json  bundles\n' > "$d/ci/release-assets.txt" ;;
            esac
            case "$r" in
                LibreKDE)  # an AppStream entry --prepare dates, beside an older one it leaves
                    mkdir -p "$d/packaging/appstream"
                    printf '<releases>\n<release version="%s" date="2000-01-01"/>\n<release version="4.2.0" date="2000-01-01"/>\n</releases>\n' "$V" \
                        > "$d/packaging/appstream/x.metainfo.xml" ;;
            esac
            case "$r" in
                LibreAgent)  # what the vendored LibreMac contract is regenerated from
                    mkdir -p "$d/wire" "$d/include/LibreSCRS/Agent/operations"
                    echo '{"schema":1,"vocabularies":{}}' > "$d/wire/wire-vocabulary.json"
                    printf '%s\n' 'inline constexpr auto kLongestDeadline{300000};' \
                        "inline constexpr auto kMaxSequentialPromptBudget = a + b; // budget-ms: 300'000" \
                        > "$d/include/LibreSCRS/Agent/operations/PromptPolicy.h" ;;
                LibreMac)
                    mkdir -p "$d/$CONTRACT"
                    echo '{"schema":1,"old":true}' > "$d/$CONTRACT/wire-vocabulary.json"
                    echo 'max-sequential-ms 1' > "$d/$CONTRACT/prompt-policy.txt" ;;
            esac
        fi
        git -C "$d" add -A && git -C "$d" commit -q -m "initial $r"
        git -C "$d" remote add origin "$top/cur/remotes/$r.git"
        git -C "$d" push -q origin main
    done
    bash "$here/bump-deps" to-head --workspace "$t/root" > "$top/template.log" 2>&1 \
        || { cat "$top/template.log"; echo "the real bump-deps to-head could not lock the template" >&2; return 1; }
    for r in "${CODE[@]}"; do git -C "$t/root/$r" push -q origin main || return 1; done
    bash "$here/bump-deps" check --workspace "$t/root" > "$top/template.log" 2>&1 \
        || { cat "$top/template.log"; echo "the template's locks are not green" >&2; return 1; }
}
template || exit 2

world() {  # world <name>: a fresh copy of the template; sets W and the environment for it
    W="$top/$1"; mkdir -p "$W/state"
    cp -a "$top/template/remotes" "$top/template/root" "$W/"
    ln -sfn "$W" "$top/cur"
    cp -a "$keys" "$W/gnupg"
    export GNUPGHOME="$W/gnupg"
    GRIP="$(gpg --batch --with-colons --with-keygrip --list-secret-keys "$PFPR" 2>/dev/null \
            | awk -F: '$1=="ssb"{s=1} s && $1=="grp"{print $10; exit}')"
    : > "$W/answers"
    export STUB_STATE="$W/state" STUB_REMOTES="$W/remotes" STUB_GRIP="$GRIP" STUB_REPOS="$top/repos"
}
train() {  # train <args...>: the subject in the current world; output to $W/out
    env PATH="$shims:$PATH" EXPECTED_FPR="$PFPR" \
        RELEASE_TRAIN_TTY="$W/answers" RELEASE_TRAIN_POLL=0 RELEASE_TRAIN_WAIT=0 \
        SITE_URL_EN=https://site/downloads/ SITE_URL_SR=https://site/sr/downloads/ \
        PACKAGES_URL=https://pkgs/packages/ PKG_REPO="$shims/pkg-repo" RELEASE_TRAIN_CI="$fci" \
        PACKAGE_KEYS="${PACKAGE_KEYS:-$top/package-signing.env}" \
        RELEASE_TRAIN_LIVE_WAIT="${RELEASE_TRAIN_LIVE_WAIT:-0}" RELEASE_TRAIN_LIVE_POLL=0 \
        RELEASE_TRAIN_PAGES_WAIT="${RELEASE_TRAIN_PAGES_WAIT:-0}" RELEASE_TRAIN_PAGES_POLL=0 \
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
LEDGER_OF() { printf '%s' "$W/root/release-train-$V.ledger"; }
publishes() { grep -c '^workflow run publish.yml .*-f mode=publish' "$W/state/gh.log" 2>/dev/null || true; }
line_of() { grep -n -m1 -E "$1" "$(LEDGER_OF)" | cut -d: -f1; }
land_remote() {  # land_remote <repo> <message>: a commit lands on origin main, the clone does not see it
    local g="$W/remotes/$1.git" n
    n="$(git --git-dir="$g" commit-tree "$(git --git-dir="$g" rev-parse 'main^{tree}')" -p main -m "$2")" \
        && git --git-dir="$g" update-ref refs/heads/main "$n"
}
remote_sha() { git --git-dir="$W/remotes/$1.git" rev-parse main; }
published_on() { awk '$1=="packages-publish" && $2=="packages" && $3=="done" { print $5 }' "$(LEDGER_OF)"; }
yes7() { answers yes yes yes yes yes yes yes yes; }
yes10() { answers yes yes yes yes yes yes yes yes yes yes yes; }
land() {  # land <repo> <message>: somebody else lands a commit on <repo>'s main
    git -C "$W/root/$1" commit -q --allow-empty -m "$2" && git -C "$W/root/$1" push -q origin main
}
relock() {  # relock <repo> <sed-expr> [push]: edit <repo>'s deps.lock; with push, land it
    sed -i.bak -E "$2" "$W/root/$1/deps.lock" && rm -f "$W/root/$1/deps.lock.bak"
    [ "${3:-}" != push ] || { git -C "$W/root/$1" commit -q -am "edit deps.lock" && git -C "$W/root/$1" push -q origin main; }
}
bd() { bash "$here/bump-deps" "$@" > "$W/out" 2>&1; }
repin() {  # repin <sha> <repo>...: each repository lands a commit pinning LibreSCRS/ci at <sha>
    local sha=$1 r; shift
    for r in "$@"; do
        pin_workflow "$W/root/$r" "$sha"
        git -C "$W/root/$r" commit -q -am "ci: LibreSCRS/ci at ${sha:0:12}" && git -C "$W/root/$r" push -q origin main || return 1
    done
}
tag_of() { git --git-dir="$W/remotes/$1.git" rev-parse "$V^{commit}"; }
lock_on_origin() { git --git-dir="$W/remotes/$1.git" show "$3:deps.lock" | awk -v d="$2" '$1 == d { print $3 }'; }

# ------------------------------------------------------------------ cases --
# T1 -- the whole train over a world that needs no lock: five tag layers and
# the site, six questions, every tag signed, pushed, released and verified.
world t1; yes7; train; rc=$?
expect_rc "T1 the whole train" 0 "$rc" "released in 7 repositories, the package repository and on the site"
assert "T1 every code repository's origin carries the signed tag" all_remote_tags
assert "T1 eight rehearsals (seven code repositories + packages) were dispatched, all mode=rehearse" \
    test "$(grep -c '^workflow run release.yml .*-f mode=rehearse' "$W/state/gh.log")" = 8
assert "T1 exactly seven questions were asked (5 tag layers + packages + site)" test "$(grep -c '^ask - yes' "$W/root/release-train-$V.ledger")" = 7
assert "T1 the package repository is published once, after the last tag layer and before the site" bash -c \
    '[ "$1" = 1 ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] && [ "$2" -lt "$3" ] && [ "$3" -lt "$4" ]' _ \
    "$(publishes)" "$(line_of '^verified LibreMac done')" "$(line_of '^packages-publish packages done')" "$(line_of '^site LibreSCRS.github.io done')"
assert "T1 the live repository was judged" grep -q "^packages-live packages done https://pkgs/packages $V" "$(LEDGER_OF)"
assert "T1 the site's download claims are checked against the packages clone" \
    grep -qF -- "--packages $W/root/packages" "$W/state/claims.args"
assert "T1 the preflight found the package key at the ci pin of all six repositories that sign" \
    test "$(grep -c "its LibreSCRS/ci pin ${CIPIN:0:12} carries the package key" "$W/out")" = 6
assert "T1 the site's download claims get keys/ at the site's ci pin (--keys)" \
    grep -qE -- "--keys [^ ]+/keys keys-present$" "$W/state/claims.args"
assert "T1 Packages.xz is read by-hash, never by its name" bash -c \
    'grep -q "/by-hash/SHA256/" "$1" && ! grep -q "binary-amd64/Packages.xz$" "$1"' _ "$W/state/curl.log"
assert "T1 the preflight ran the Valid-Until guard over the live repository" \
    grep -qx -- "watch --url https://pkgs/packages --keyset package-signing --min-days 14" "$W/state/pkg-repo.log"
assert "T1 the site's origin publishes the release's data" \
    bash -c 'git --git-dir="$1" show main:data/artifacts.json | grep -q "\"ref\": \"$2\""' _ "$W/remotes/$SITE.git" "$V"
assert "T1 the tag object on origin verifies against KEYS" \
    env REPO_ROOT="$W/root/LibreAgent" EXPECTED_FPR="$PFPR" bash "$here/verify-release-tag.sh" tag "$V"
assert "T1 LibreLinux's released deps.lock names the LibreAgent and LibreMiddleware tag commits" bash -c \
    '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$(lock_on_origin LibreLinux LibreAgent "$V")" "$(tag_of LibreAgent)" \
    "$(lock_on_origin LibreLinux LibreMiddleware "$V")" "$(tag_of LibreMiddleware)"
# T1b-d -- the tag-day check itself, the real bump-deps over the released world:
# the lock the train froze IS the tag, and nothing but the commit is judged.
bd check --root "$W/root/LibreLinux" --tag "$V"
expect_rc "T1b check --tag on a released consumer" 0 "$?" "is $V"
relock LibreLinux "s/^(LibreAgent[[:space:]]+[^[:space:]]+[[:space:]]+)[0-9a-f]{40}/\\1$(git -C "$W/root/LibreAgent" rev-parse "$V^{commit}~1")/"
bd check --root "$W/root/LibreLinux" --tag "$V"
expect_rc "T1c check --tag: a lock one commit short of the tag" 1 "$?" "but $V is"
git -C "$W/root/LibreLinux" checkout -q -- deps.lock
relock LibreLinux "s/^(LibreAgent[[:space:]].*)$/\\1  $V/"
bd check --root "$W/root/LibreLinux" --tag "$V"
expect_rc "T1d check --tag: a fourth column, even one naming the tag, is refused" 1 "$?" "drop column 4"
git -C "$W/root/LibreLinux" checkout -q -- deps.lock

# T2 -- --rehearse-only: every rehearsal, no question, nothing pushed.
world t2; : > "$W/answers"; train --rehearse-only; rc=$?
expect_rc "T2 rehearse-only" 0 "$rc" "nothing was pushed"
assert "T2 no tag reached any origin" no_remote_tags
assert "T2 eight rehearsals dispatched (seven code repositories + packages)" test "$(dispatches)" = 8
assert "T2 packages' release.yml was rehearsed" grep -q '^workflow run release.yml -R LibreSCRS/packages --ref main -f mode=rehearse' "$W/state/gh.log"
runs_want="$(for r in LibreMiddleware LibreAgent LibreLinux LibreCelik LibreKDE packages; do
    printf '%s=%s ' "$r" "$(awk -v r="$r" '$1=="rehearse" && $2==r && $3=="done" { print $4 }' "$(LEDGER_OF)")"; done)"
assert "T2 publish.yml mode=rehearse got the six rehearsal run ids of the ledger" \
    grep -qx -- "workflow run publish.yml -R LibreSCRS/packages --ref main -f mode=rehearse -f runs=${runs_want% }" "$W/state/gh.log"
assert "T2 six ids, each a run id" bash -c '[ "$(wc -w <<<"$1")" -eq 6 ] && ! grep -q "=\( \|$\)" <<<"$1"' _ "${runs_want% }"
assert "T2 the publisher rehearsal is in the ledger, and nothing was published" bash -c \
    'grep -Eq "^packages-rehearse packages done [0-9]+" "$1" && [ "$2" = 0 ]' _ "$(LEDGER_OF)" "$(publishes)"

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
world t9b; yes7; STUB_GH_OTHER_BROKEN=1 train; rc=$?
expect_rc "T9b a broken second stored gh account does not stop the train" 0 "$rc" "gh: stub-user"
world t10; relock LibreCelik "s/^(LibreAgent[[:space:]]+[^[:space:]]+[[:space:]]+)[0-9a-f]{40}/\\1$(printf 'a%.0s' {1..40})/" push
yes7; train; rc=$?
expect_rc "T10 a lock naming a commit upstream does not have" 1 "$rc" "does not exist upstream"
assert "T10 and the train says so before anything moves" bash -c 'grep -q "bump-deps check is not green" "$1" && ! grep -q "^workflow run" "$2" 2>/dev/null' _ "$W/out" "$W/state/gh.log"

# T11 -- LibreMiddleware moved after the last lock: the real bump-deps locks
# every layer below it in turn (LA, then LL+LD on the new LA, then LC+LK, then
# LMAC), one question per layer, and every tag layer's `check --tag` is the
# real tool holding those fresh locks to the tags the layer above just pushed.
world t11; land LibreMiddleware "a late fix"
yes10; train; rc=$?
expect_rc "T11 a behind lock is bumped, confirmed and pushed" 0 "$rc" "LibreAgent: 1 commit(s) on top of origin main"
assert "T11 four lock layers + five tag layers + packages + the site: eleven questions" \
    test "$(grep -c '^ask - yes' "$W/root/release-train-$V.ledger")" = 11
assert "T11 the bump commit is on LibreAgent's origin main" \
    bash -c 'git --git-dir="$1" log -1 --format=%s main | grep -Eqx "build: track LibreMiddleware [0-9a-f]{12}"' _ "$W/remotes/LibreAgent.git"
assert "T11 LibreAgent's tag is on the bump commit" \
    bash -c '[ "$(git --git-dir="$1" rev-parse "$2^{commit}")" = "$(git --git-dir="$1" rev-parse main)" ]' _ "$W/remotes/LibreAgent.git" "$V"
assert "T11 LibreAgent's released lock is LibreMiddleware's tag, LibreMac's is LibreDarwin's" bash -c \
    '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$(lock_on_origin LibreAgent LibreMiddleware "$V")" "$(tag_of LibreMiddleware)" \
    "$(lock_on_origin LibreMac LibreDarwin "$V")" "$(tag_of LibreDarwin)"

# T12 -- a lock is behind and the answer is no: nothing is pushed.
world t12; land LibreMiddleware "a late fix"; answers no; train; rc=$?
expect_rc "T12 declining the lock push" 1 "$rc" "not confirmed -- nothing pushed"
assert "T12 LibreAgent's origin main did not move" \
    test "$(git --git-dir="$W/remotes/LibreAgent.git" rev-parse main)" = "$(git --git-dir="$top/template/remotes/LibreAgent.git" rev-parse main)"

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
assert "T14 the rehearsals were not dispatched twice" test "$(dispatches)" = 8

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
world t23; answers yes yes yes yes yes yes yes yes yes yes yes yes; train --prepare; rc=$?
expect_rc "T23 --prepare" 0 "$rc" "released in 7 repositories"
assert "T23 every origin CHANGELOG now heads [$V] — <date>" bash -c '
    for r in LibreMiddleware LibreAgent LibreLinux LibreDarwin LibreCelik LibreKDE LibreMac; do
        git --git-dir="$1/$r.git" show "$2:CHANGELOG.md" | grep -q "^## \[$2\] — [0-9-]*\$" || exit 1
    done' _ "$W/remotes" "$V"
assert "T23 the $V AppStream entry carries the heading's date, the older one keeps its own" bash -c '
    x="$(git --git-dir="$1/LibreKDE.git" show "$2:packaging/appstream/x.metainfo.xml")"
    d="$(git --git-dir="$1/LibreKDE.git" show "$2:CHANGELOG.md" | sed -n "s/^## \[$2\] — //p")"
    grep -qF "<release version=\"$2\" date=\"$d\"/>" <<<"$x" &&
    grep -qF "<release version=\"4.2.0\" date=\"2000-01-01\"/>" <<<"$x"' _ "$W/remotes" "$V"

# T24 -- the consumer's locks do not name the upstream tags at tag time.
# T24 -- a lock in the old four-column form: under the old tool it passed every
# check until tag day, then failed `check --tag` on its column 4. Now it is a
# finding at the preflight, before anything is pushed or tagged.
world t24; relock LibreLinux "s/^(LibreAgent[[:space:]].*)$/\\1  main/" push
yes7; train; rc=$?
expect_rc "T24 a four-column lock stops the train at the preflight" 1 "$rc" "drop column 4"
assert "T24 no tag on any origin" no_remote_tags

# T28-T38 -- the package repository.
# T28 -- a train stopped because the CDN still served the previous generation
# leaves the repository published; --resume does not publish it again, judges
# the live repository again and goes on to the site.
world t28; yes7; STUB_REPO_STALE=99 train; rc=$?
expect_rc "T28 stopped at the live check after the package repository is published" 1 "$rc" "does not serve $V"
assert "T28 published once" test "$(publishes)" = 1
yes7; train --resume; rc=$?
expect_rc "T28b --resume after packages-publish done" 0 "$rc" "packages: published earlier"
assert "T28b and judged the live repository, then the site" bash -c \
    '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$(line_of '^packages-live packages done')" "$(line_of '^site LibreSCRS.github.io done')"
assert "T28b publish.yml mode=publish was not dispatched again" test "$(publishes)" = 1
assert "T28b the publisher rehearsal was not dispatched again" \
    test "$(grep -c '^workflow run publish.yml .*-f mode=rehearse' "$W/state/gh.log")" = 1

# T29/T30/T31 -- the live repository is not the release; the train stops before the site.
world t29; yes7; STUB_REPO=rpmsig train; rc=$?
expect_rc "T29 InRelease signed by the rpm subkey, not the index subkey" 1 "$rc" "is not signed by the index subkey $S_IDX of $PKFPR (signed by $S_RPM of $PKFPR)"
assert "T29 the site was not pushed" bash -c '[ "$(git --git-dir="$1" log -1 --format=%s main)" = "initial LibreSCRS.github.io" ]' _ "$W/remotes/$SITE.git"
world t30; yes7; STUB_REPO=badver train; rc=$?
expect_rc "T30 librecelik $V-1 without the ~deb13 suffix" 1 "$rc" "carries no librecelik $V-1~deb13 (it has: $V-1)"
world t31; yes7; STUB_REPO=rpmold train; rc=$?
expect_rc "T31 the fedora44 primary still the previous release" 1 "$rc" "the fedora44 primary carries no librecelik $V"

# T32/T33 -- the CDN: the previous generation twice, then this one, passes;
# the previous one past the window stops the train.
world t32; yes7; STUB_REPO_STALE=2 RELEASE_TRAIN_LIVE_WAIT=5 train; rc=$?
expect_rc "T32 the previous generation twice, then the new one" 0 "$rc" "released in 7 repositories"
assert "T32 two looks were refused, the third passed" test "$(grep -c 'not live yet: trixie Packages.xz carries no librecelik' "$W/out")" = 2
world t33; yes7; STUB_REPO_STALE=99 RELEASE_TRAIN_LIVE_WAIT=3 train; rc=$?
expect_rc "T33 still the previous generation when the window closes" 1 "$rc" "does not serve $V after 3s"
assert "T33 four looks (window 3, poll 0 -> 1 s each), then the stop" test "$(grep -c 'not live yet' "$W/out")" = 4

# T34-T37 -- the preflight refuses, and nothing moves.
world t34; yes7; STUB_CI_RED=packages train; rc=$?
expect_rc "T34 packages' ci.yml red on its main" 1 "$rc" "packages: ci.yml is not green"
assert "T34 nothing dispatched" bash -c '[ "$(grep -c "^workflow run" "$1" 2>/dev/null || true)" = 0 ]' _ "$W/state/gh.log"
world t35; yes7; PACKAGE_KEYS="$W/no-package-signing.env" train; rc=$?
expect_rc "T35 no keys/package-signing.env" 1 "$rc" "no $W/no-package-signing.env"
assert "T35 stopped at the preflight: nothing dispatched" bash -c '[ "$(grep -c "^workflow run" "$1" 2>/dev/null || true)" = 0 ]' _ "$W/state/gh.log"
world t35b; yes7; PACKAGE_CERT="$W/no-package-signing.asc" train; rc=$?
expect_rc "T35b no package certificate beside the env" 1 "$rc" "no $W/no-package-signing.asc -- the package signing certificate"
assert "T35b stopped at the preflight: nothing dispatched" bash -c '[ "$(grep -c "^workflow run" "$1" 2>/dev/null || true)" = 0 ]' _ "$W/state/gh.log"
world t36; yes7; PACKAGE_CERT="$top/KEY-uncertified.asc" train; rc=$?
expect_rc "T36 a package certificate the release key has not certified" 1 "$rc" "carries no valid certification by the release key"
assert "T36 stopped at the preflight: nothing dispatched" bash -c '[ "$(grep -c "^workflow run" "$1" 2>/dev/null || true)" = 0 ]' _ "$W/state/gh.log"
world t37; yes7; STUB_WATCH_RC=1 train; rc=$?
expect_rc "T37 the Valid-Until guard red on the live repository" 1 "$rc" "pkg-repo.py watch is not green"
assert "T37 nothing dispatched" bash -c '[ "$(grep -c "^workflow run" "$1" 2>/dev/null || true)" = 0 ]' _ "$W/state/gh.log"
world t38; git -C "$W/root/packages" commit -q --allow-empty -m local; yes7; train; rc=$?
expect_rc "T38 the packages clone is behind its origin" 1 "$rc" "packages: HEAD"
world t36b; yes7; PACKAGE_CERT="$top/KEY-revoked.asc" train; rc=$?
expect_rc "T36b the release key revoked its certification of the package key" 1 "$rc" "carries no valid certification by the release key"
world t37b; yes7; STUB_WATCH_RC=2 train; rc=$?
expect_rc "T37b the Valid-Until guard cannot judge: so cannot the train" 2 "$rc" "pkg-repo.py watch could not judge"

# T39 -- the right index subkey, but the env names another (certified) primary.
# The certificate is the .asc beside the env (package-signing-other.asc).
world t39; repin "$CIPIN_OTHER" "${SIGNING[@]}"; answers yes yes yes yes yes yes yes yes yes yes yes yes yes yes
PACKAGE_KEYS="$top/package-signing-other.env" train; rc=$?
expect_rc "T39 InRelease signed by S_IDX of another primary than PACKAGE_FPR" 1 "$rc" "is not signed by the index subkey $S_IDX of $OFPR (signed by $S_IDX of $PKFPR)"
assert "T39 the preflight passed: the other key is certified" grep -q "package key ${OFPR:0:16}... certified" "$W/out"

# T46-T48 -- a repository that signs packages pins a ci whose package key is
# not this one, a ci commit this clone does not have, or no single ci commit:
# the preflight stops before anything is frozen or tagged.
world t46; repin "$CIPIN_UNCERT" LibreCelik; yes7; train; rc=$?
expect_rc "T46 LibreCelik pins a ci whose package certificate is another" 1 "$rc" \
    "LibreCelik: keys/package-signing.asc at its LibreSCRS/ci pin ${CIPIN_UNCERT:0:12} is not"
assert "T46 stopped at the preflight: nothing dispatched, no tag" bash -c \
    '[ "$(grep -c "^workflow run" "$1" 2>/dev/null || true)" = 0 ]' _ "$W/state/gh.log"
assert "T46 the other five pins were judged and carry the key" \
    test "$(grep -c "its LibreSCRS/ci pin ${CIPIN:0:12} carries the package key" "$W/out")" = 5
world t47; repin 0123456789abcdef0123456789abcdef01234567 packages; yes7; train; rc=$?
expect_rc "T47 packages pins a ci commit this ci clone does not have: cannot judge" 2 "$rc" \
    "packages: LibreSCRS/ci 0123456789ab (its workflows' pin) is not in $fci: fetch ci"
world t48; printf '      - uses: LibreSCRS/ci/actions/gates@%s\n' "$CIPIN_OTHER" >> "$W/root/LibreAgent/.github/workflows/release.yml"
git -C "$W/root/LibreAgent" commit -q -am "a second pin" && git -C "$W/root/LibreAgent" push -q origin main
yes7; train; rc=$?
expect_rc "T48 LibreAgent pins two ci commits" 1 "$rc" "LibreAgent: no single LibreSCRS/ci pin in .github/workflows"
world t48b; printf '      # was: - uses: LibreSCRS/ci/actions/gates@%s\n' "$CIPIN_OTHER" >> "$W/root/LibreAgent/.github/workflows/release.yml"
git -C "$W/root/LibreAgent" commit -q -am "a commented-out old pin" && git -C "$W/root/LibreAgent" push -q origin main
yes7; train --rehearse-only; rc=$?
expect_rc "T48b a commented-out pin is no pin: LibreAgent still pins one ci commit" 0 "$rc" \
    "LibreAgent: its LibreSCRS/ci pin ${CIPIN:0:12} carries the package key"

# T40 -- the first real publish is red after the tags are out; a fix lands on
# packages' main (the clone does not even have it), and --resume publishes on it.
world t40; yes7; STUB_PUBLISH_RED=1 train; rc=$?
expect_rc "T40 a red publish after the tags" 1 "$rc" "publish.yml run"
land_remote packages "fix publish.yml"
yes7; train --resume; rc=$?
expect_rc "T40b --resume after a fix landed on packages' main" 0 "$rc" "released in 7 repositories"
assert "T40b published on the fix, not the frozen commit" bash -c \
    '[ "$1" = "sha=$2" ] && [ "$2" != "$3" ]' _ "$(published_on)" "$(remote_sha packages)" \
    "$(awk '$1=="freeze" && $2=="packages" { print $4 }' "$(LEDGER_OF)")"
assert "T40b publish.yml mode=publish dispatched twice" test "$(publishes)" = 2
# T49-T51 -- watch's "404 after a release" is the train's own state between
# its first tag and the first publish, and only there: a --resume then
# proceeds; before any tag, and after the publish, the same answer stops it.
world t49; yes7; STUB_PUBLISH_RED=1 train; land_remote packages "fix publish.yml"
yes7; STUB_WATCH_404=1 train --resume; rc=$?
expect_rc "T49 --resume after a red first publish, nothing deployed yet: watch's 404 is expected" 0 "$rc" \
    "watch: no published repository yet -- expected, the tags are out and packages has not published"
world t50; yes7; STUB_WATCH_404=1 train; rc=$?
expect_rc "T50 watch's 404-after-release before any tag stops the preflight" 1 "$rc" "pkg-repo.py watch is not green"
assert "T50 nothing dispatched" bash -c '[ "$(grep -c "^workflow run" "$1" 2>/dev/null || true)" = 0 ]' _ "$W/state/gh.log"
world t51; yes7; STUB_CLAIMS_RED=1 train
yes7; STUB_WATCH_404=1 train --resume; rc=$?
expect_rc "T51 after packages published, watch's 404 stops a --resume" 1 "$rc" "pkg-repo.py watch is not green"
assert "T51 the first run had published" grep -q '^packages-publish packages done' "$(LEDGER_OF)"
# T45 -- the same, but CI is red on the fix: nothing is dispatched on it.
world t45; yes7; STUB_PUBLISH_RED=1 train; land_remote packages "a fix whose CI is red"
yes7; STUB_CI_RED=packages train --resume; rc=$?
expect_rc "T45 --resume onto a packages main whose CI is red" 1 "$rc" "packages: ci.yml is not green on"
assert "T45 publish.yml mode=publish not dispatched again" test "$(publishes)" = 1

# T41 -- packages' main moves while the tags are out: the publish is watched on
# the commit it was dispatched on.
world t41; yes7; STUB_MOVE_PACKAGES=1 train; rc=$?
expect_rc "T41 packages moved during the tag layers" 0 "$rc" "released in 7 repositories"
assert "T41 the publish ran on the moved main" bash -c \
    '[ -f "$1/moved" ] && [ "$2" = "sha=$3" ]' _ "$W/state" "$(published_on)" "$(remote_sha packages)"

# T42/T43 -- the site: declining its push, then --resume, pushes the same
# commit; a page still old past the window stops, and --resume finishes.
world t42; answers yes yes yes yes yes yes no; train; rc=$?
expect_rc "T42 declining the site push" 1 "$rc" "not confirmed"
yes7; train --resume; rc=$?
expect_rc "T42b --resume after the declined site push" 0 "$rc" "released in 7 repositories"
assert "T42b the site's origin carries the train's one site commit" bash -c \
    '[ "$(git --git-dir="$1" log -1 --format=%s main)" = "Downloads: release $2" ] && [ "$(git --git-dir="$1" rev-list --count main)" = 2 ]' \
    _ "$W/remotes/$SITE.git" "$V"
world t43; yes7; STUB_SITE_STALE=99 train; rc=$?
expect_rc "T43 the download page still old after the deploy" 1 "$rc" "does not name $V yet"
STUB_SITE_STALE=0 train --resume; rc=$?
expect_rc "T43b --resume after the site push" 0 "$rc" "released in 7 repositories"
world t44; yes7; STUB_SITE_STALE=2 RELEASE_TRAIN_PAGES_WAIT=5 train; rc=$?
expect_rc "T44 the old page twice, then the new one" 0 "$rc" "released in 7 repositories"
assert "T44 two looks were refused" test "$(grep -c 'not yet: https://site/downloads/ does not name' "$W/out")" = 2

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
# P4 -- without the check of the signing repositories' pins, T46's train
# passes the preflight and goes on to rehearse: the check is what stops it.
if perturb '    signing_pins_carry_package_key || bad=1' '    :'; then
    world p4; repin "$CIPIN_UNCERT" LibreCelik; yes7
    subject_real=$subject; subject=$perturbed; train --rehearse-only; subject=$subject_real
    cases=$((cases + 1)); red=$((red + 1))
    if grep -q "^workflow run release.yml" "$W/state/gh.log" 2>/dev/null; then
        pass "P4 without the pin check the train rehearses over a pin without the package key -- T46 discriminates"
    else fail "P4 the train stopped without the pin check -- T46 proves nothing" "$W/out"; fi
else
    cases=$((cases + 1)); fail "P4 the clause to perturb is not in the train"
fi
# P5 -- without the exemption, T49's --resume dies at its preflight.
if perturb '        if [ "$watch_rc" = 1 ] && tags_started' '        if false && tags_started'; then
    world p5; yes7; STUB_PUBLISH_RED=1 train; land_remote packages "fix publish.yml"
    yes7; subject_real=$subject; subject=$perturbed; STUB_WATCH_404=1 train --resume; rc=$?; subject=$subject_real
    cases=$((cases + 1)); red=$((red + 1))
    if [ "$rc" = 1 ] && grep -q "pkg-repo.py watch is not green" "$W/out"; then
        pass "P5 without the exemption the --resume dies at the preflight -- T49 discriminates"
    else fail "P5 the --resume got through without the exemption (rc=$rc) -- T49 proves nothing" "$W/out"; fi
else
    cases=$((cases + 1)); fail "P5 the clause to perturb is not in the train"
fi
rm -f "$perturbed"

# P3 -- a bump-deps whose to-head writes column 4 again (the defect this format
# change removed) must be stopped before any tag: the real check refuses what
# the regressed writer produced, at the freeze.
pbd="$here/.bump-deps.perturbed.$$"
trap 'rm -f "$perturbed" "$pbd"; cleanup' EXIT
old_w="printf '%-16s %-46s %s\\n' \"\$d\" \"\$URL_BASE/\$d\" \"\${T_SHA[\$d]}\""
cases=$((cases + 1)); red=$((red + 1))
if python3 - "$here/bump-deps" "$pbd" "$old_w" <<'PYP'
import sys
src, dst, old = sys.argv[1:4]
t = open(src).read()
if old not in t:
    sys.exit(1)
open(dst, "w").write(t.replace(old, old.replace("%s\\n", "%s  main\\n")))
PYP
then
    chmod 755 "$pbd"
    world p3; land LibreMiddleware "a late fix"; yes10
    BUMP_DEPS="$pbd" train; rc=$?
    if [ "$rc" = 1 ] && grep -q "freeze failed" "$W/out" && no_remote_tags; then
        pass "P3 a to-head that writes column 4 again is stopped at the freeze, no tag pushed"
    else
        fail "P3 the column-4 writer was not stopped before the tags (rc=$rc)" "$W/out"
    fi
else
    fail "P3 the clause to perturb is not in bump-deps"
fi
rm -f "$pbd"

if [ "$fails" -eq 0 ]; then
    echo "release-train selftest: all cases passed"
else
    echo "release-train selftest: $fails case(s) failed"
fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fails" -eq 0 ]
