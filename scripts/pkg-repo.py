#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""pkg-repo.py -- the publisher of the LibreSCRS package repositories.

  select          which release tags a repository tree is built from
  fetch-releases  download each release and verify it: the exact asset set
                  against the repository's ci/release-assets.txt, provenance
                  through release-seal.sh verify-release, and the RPM
                  signatures through pkg-sign.sh --verify-only

Layout of --out: <out>/<Repo>/<tag>/ (rehearse: <out>/<Repo>/rehearse/).
With --allow-none (publish only), no code repository having a release tag at
or above its minimum -- the time before the first release -- writes
<out>/NONE with the reason and is rc 0, whether or not the packages repository
has released (it is tagged first); one code repository without a tag while
another has one stays a finding.

Environment (the self-test replaces them with fakes):
  PKG_REPO_GH    the gh command            (default: gh)
  PKG_REPO_SEAL  release-seal.sh           (default: next to this script)
  PKG_REPO_SIGN  pkg-sign.sh               (default: next to this script)
  RUNS           rehearse only: "<Repo>=<run id>" for every repository,
                 separated by spaces or commas

assemble reads that layout (--in), writes <out>/{deb,rpm,KEY.asc,KEYS,index.html}
and judges nothing it cannot read: a package of the wrong distribution is a
finding, a missing KEYS or a Docker that fails is "cannot judge". With --prev
(a fetch-prev mirror) it keeps, for one more generation, what the new one no
longer names: by-hash files, repodata files and the pool files the previous
index referenced -- so a client holding a cached old index finds every file it
names.

fetch-prev mirrors the previous published generation from the live site into
--out, and only through signed indexes (Pages cannot list a directory):
InRelease, the by-hash and Packages* files it names, the pool files Packages
names; repomd.xml(.asc), the files repomd.xml names and the rpms primary
names; KEY.asc, KEYS and the stable aliases (the keyring and release packages
the install instructions download first), each alias only when an index
names its bytes -- a keyring alias its codename's, a release package alias
any rpm slug's, a slug index.html links to included, so a slug this code no
longer builds can still be the source -- so the mirror is the site as a user
meets it. Every
signature is checked with gpgv against the key set's certificate and accepted
only when it is made by S_IDX_FPR; every hash is checked. Nothing stays in
--out unless all of it holds. No InRelease for trixie (HTTP 404) means "no
published generation": <out>/EMPTY, rc 0, judged before the key set is read
(before the first publish it need not exist yet).

sign-index signs the indexes of an assembled tree with the key set's index
subkey (exactly S_IDX_FPR): InRelease (clearsigned) and Release.gpg (binary,
detached) for every codename, repodata/repomd.xml.asc (armored, detached) for
every slug. The secret part is --key, a file holding the armored subkey; for
the rehearsal key set it defaults to keys/rehearsal.sec.asc. It is imported
into a GNUPGHOME of its own, and every signature is checked as verify-tree
would before any is written.

verify-tree judges a whole tree before it is published, with the checks
fetch-prev applies to a mirror: the signature of every index (gpgv, made by
S_IDX_FPR), the hash chain Release -> Packages* -> pool and by-hash, repomd.xml
-> the files it names -> the rpms primary names, repomd.xml.key and KEY.asc
being the key set's certificate; and further Valid-Until later than --now, the
stable aliases being packages an index names, and the rpm signatures through
pkg-sign.sh --verify-only. --unsigned judges the hash chain of a tree not yet
signed and no signature at all.

  PKG_REPO_INDEX  pkg-repo-index.sh        (default: next to this script)

watch guards the live site between publishes: the InRelease of every codename
must verify (gpgv, made by S_IDX_FPR) and its Valid-Until lie more than
--min-days ahead, so a scheduled re-sign that stopped running turns red while
apt still accepts the repository. No InRelease for trixie (HTTP 404) is "not
yet published", rc 0, only while no code repository has a release at or above
its minimum (the rule fetch-releases --allow-none applies, through gh); once
one has, a 404 is a finding: the published repository is gone. PKG_REPO_NOW
(epoch seconds) stands in for the clock.

Exit codes: 0 green, 1 a finding, 2 cannot judge (never a pass).
"""
import argparse
import email.utils
import gzip
import hashlib
import json
import lzma
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ORG = "LibreSCRS"
# (repository, keep, minimum version)
REPOS = [
    ("LibreMiddleware", 2, "5.0.0"),
    ("LibreAgent", 2, "5.0.0"),
    ("LibreLinux", 2, "5.0.0"),
    ("LibreCelik", 2, "5.0.0"),
    ("LibreKDE", 2, "5.0.0"),
    ("packages", 1, "1.0.0"),
]
SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


class Cannot(Exception):
    """Nothing could be judged: exit 2."""


def vkey(tag):
    m = SEMVER.match(tag)
    return tuple(int(x) for x in m.groups()) if m else None


def select_tags(releases, keep, minimum):
    floor = vkey(minimum)
    if floor is None or keep < 1:
        raise Cannot("bad --min/--keep")
    if not isinstance(releases, list):
        raise Cannot("the releases are not a JSON list")
    found = []
    for r in releases:
        if not isinstance(r, dict):
            raise Cannot(f"a release that is not a JSON object: {r!r:.60}")
        if r.get("prerelease") or r.get("draft"):
            continue
        tag = r.get("tag_name", "")
        k = vkey(tag)
        if k is not None and k >= floor:
            found.append((k, tag))
    found.sort(reverse=True)
    return [t for _, t in found[:keep]]


def cmd_select(a):
    try:
        with open(a.releases) if a.releases != "-" else sys.stdin as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print(f"pkg-repo: cannot read the releases: {e} -- cannot judge", file=sys.stderr)
        return 2
    try:
        tags = select_tags(data, a.keep, a.min)
    except Cannot as e:
        print(f"pkg-repo: {e} -- cannot judge", file=sys.stderr)
        return 2
    except Exception as e:  # nothing unexpected is a pass, and none is a finding
        print(f"::error::select: unexpected {type(e).__name__}: {e} -- cannot judge")
        return 2
    if not tags:
        print(f"::error::no release tag >= {a.min} (not a prerelease or draft)", file=sys.stderr)
        return 1
    print("\n".join(tags))
    return 0


# ------------------------------------------------------------------ fetch --
def gh_cmd():
    return shlex.split(os.environ.get("PKG_REPO_GH", "gh"))


def run(argv, **kw):
    kw.setdefault("text", True)
    try:
        return subprocess.run(argv, capture_output=True, **kw)
    except OSError as e:
        raise Cannot(f"cannot run {argv[0]}: {e}")


def gh(*args):
    p = run(gh_cmd() + list(args))
    if p.returncode != 0:
        raise Cannot(f"gh {' '.join(args[:3])} failed: {p.stderr.strip()}")
    return p.stdout


def tool(env, script):
    return shlex.split(os.environ.get(env) or os.path.join(HERE, script))


def check_set(d, decl_text, label):
    """The files in d are exactly the declared set, in both directions.

    Matching is check-release-assets.sh --staged, called rather than copied:
    its parsing and its glob semantics are the one definition. Two things it
    does not say are said here: an empty directory is judged first, since a
    release with no asset is no release, and its rc 2 stays 2.
    """
    names = os.listdir(d)
    if not names:
        print(f"::error::{label}: no asset downloaded into {d}")
        return 1
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR", "/var/tmp")) as t:
        decl = os.path.join(t, "release-assets.txt")
        with open(decl, "w") as f:
            f.write(decl_text)
        env = dict(os.environ, RELEASE_ASSETS_FILE=decl, REPO_ROOT=t)
        p = run(["bash", os.path.join(HERE, "check-release-assets.sh"), "--staged", d], env=env)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    if p.returncode != 0:
        print(f"::error::{label}: the asset set is not the declared one (rc {p.returncode})")
    return p.returncode


def verify_rpms(d, keyset, label):
    if not any(n.endswith(".rpm") for n in os.listdir(d)):
        return 0
    p = run(tool("PKG_REPO_SIGN", "pkg-sign.sh") + ["--dir", d, "--keyset", keyset, "--verify-only"])
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    if p.returncode != 0:
        print(f"::error::{label}: rpm signatures not verified (rc {p.returncode})")
    return p.returncode


def publish_tags(repo, keep, minimum):
    releases = json.loads(gh("api", f"repos/{ORG}/{repo}/releases?per_page=100"))
    return select_tags(releases, keep, minimum)


# The code repositories decide whether anything is released: the packages
# repository is tagged before them.
CODE_REPOS = [(repo, keep, minimum) for repo, keep, minimum in REPOS if repo != "packages"]


def released_code(tags=None):
    """The code repositories with a release tag at or above their minimum.
    None of them is the time before the first release. tags: {repo: tags}
    already read; None reads them through gh."""
    if tags is None:
        tags = {repo: publish_tags(repo, keep, minimum) for repo, keep, minimum in CODE_REPOS}
    return [repo for repo, _, _ in CODE_REPOS if tags[repo]]


def fetch_publish(out, repo, tags, minimum):
    full = f"{ORG}/{repo}"
    if not tags:
        print(f"::error::{repo}: no release tag >= {minimum}")
        return 1
    worst = 0
    for tag in tags:
        label = f"{repo} {tag}"
        d = os.path.join(out, repo, tag)
        os.makedirs(d, exist_ok=True)
        gh("release", "download", tag, "-R", full, "-D", d)
        decl = gh("api", f"repos/{full}/contents/ci/release-assets.txt?ref={tag}",
                  "-H", "Accept: application/vnd.github.raw")
        rc = check_set(d, decl, label)
        if rc == 0:
            p = run(tool("PKG_REPO_SEAL", "release-seal.sh") + ["verify-release", d, full, f"refs/tags/{tag}"])
            sys.stdout.write(p.stdout)
            sys.stderr.write(p.stderr)
            rc = p.returncode
            if rc != 0:
                print(f"::error::{label}: provenance not verified (rc {rc})")
        if rc == 0:
            rc = verify_rpms(d, "package-signing", label)
        worst = merge(worst, rc)
    return worst


def parse_runs(text):
    runs = {}
    for item in re.split(r"[\s,]+", text.strip()):
        if not item:
            continue
        name, sep, rid = item.partition("=")
        if not sep or not rid.isdigit():
            raise Cannot(f"RUNS entry '{item}' is not <Repo>=<run id>")
        runs[name] = rid
    missing = [r for r, _, _ in REPOS if r not in runs]
    if missing:
        raise Cannot(f"runs names {len(runs)} of {len(REPOS)} repositories: {', '.join(missing)} missing")
    return runs


def fetch_rehearse(out, repo, rid):
    full = f"{ORG}/{repo}"
    d = os.path.join(out, repo, "rehearse")
    os.makedirs(d, exist_ok=True)
    gh("run", "download", rid, "-R", full, "-n", "release-rehearsal", "-D", d)
    decl = gh("api", f"repos/{full}/contents/ci/release-assets.txt?ref=main",
              "-H", "Accept: application/vnd.github.raw")
    label = f"{repo} rehearse"
    rc = check_set(d, decl, label)
    if rc == 0:
        if not os.path.isfile(os.path.join(d, "SHA256SUMS")):
            print(f"::error::{label}: no SHA256SUMS")
            rc = 1
        else:
            p = run(["sha256sum", "-c", "SHA256SUMS"], cwd=d)
            sys.stdout.write(p.stdout)
            sys.stderr.write(p.stderr)
            rc = 1 if p.returncode else 0
            if rc:
                print(f"::error::{label}: SHA256SUMS does not hold")
    if rc == 0:
        print("cosign skipped: a rehearsal signs with an ephemeral key (release-seal.sh)")
        rc = verify_rpms(d, "rehearsal", label)
    return rc


def merge(worst, rc):
    return 2 if 2 in (worst, rc) else max(worst, rc)


def cmd_fetch(a):
    out = os.path.abspath(a.out)
    worst = 0
    try:
        if a.mode == "publish":
            tags = {repo: publish_tags(repo, keep, minimum) for repo, keep, minimum in REPOS}
            # Before the first release nothing is missing: there is nothing yet.
            # One code repository released without the others is still a finding.
            if a.allow_none and not released_code(tags):
                os.makedirs(out, exist_ok=True)
                reason = "no code repository has a release tag at or above its minimum: " + ", ".join(
                    f"{repo} >= {minimum}" for repo, _, minimum in CODE_REPOS)
                with open(os.path.join(out, "NONE"), "w") as f:
                    f.write(reason + "\n")
                print(f"pkg-repo: {reason} -- nothing released yet ({out}/NONE)")
                return 0
            for repo, _, minimum in REPOS:
                worst = merge(worst, fetch_publish(out, repo, tags[repo], minimum))
        else:
            if a.allow_none:
                raise Cannot("--allow-none is for --mode publish; a rehearsal always names its runs")
            runs = parse_runs(os.environ.get("RUNS", ""))
            for repo, _, _ in REPOS:
                worst = merge(worst, fetch_rehearse(out, repo, runs[repo]))
    except Cannot as e:
        print(f"pkg-repo: {e} -- cannot judge", file=sys.stderr)
        return 2
    except ValueError as e:
        print(f"pkg-repo: unreadable gh answer: {e} -- cannot judge", file=sys.stderr)
        return 2
    except Exception as e:  # nothing unexpected is a pass, and none is a finding
        print(f"::error::fetch-releases: unexpected {type(e).__name__}: {e} -- cannot judge")
        return 2
    return worst


# --------------------------------------------------------------- assemble --
# slug -> (apt codename, the Version suffix a package built for it carries)
DEB_SLUGS = {"debian13": ("trixie", "~deb13"), "ubuntu2604": ("resolute", "~ubuntu26.04")}
RPM_SLUGS = ("fedora43", "fedora44", "opensusetw")
CODENAMES = ("trixie", "resolute")
KEYRING_DEB = "librescrs-archive-keyring"
KEYRING_RPM = re.compile(r"^librescrs-release-\d")
# the stable alias of the release package, and the build it is taken from
RPM_ALIASES = {"librescrs-release-fedora.noarch.rpm": "fedora43",
               "librescrs-release-opensusetw.noarch.rpm": "opensusetw"}
# The stable alias -> the codename or slug whose index must name its bytes.
ALIASES = dict({f"{KEYRING_DEB}-{c}.deb": c for c in CODENAMES}, **RPM_ALIASES)
# Every file the tree holds gets this mtime: createrepo_c records it, and two
# assembles of the same assets must not differ by when they were copied.
FIXED_MTIME = 0


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def release_file(suite, files, now, valid_days):
    rfc = lambda t: email.utils.formatdate(t, usegmt=True)
    head = ["Origin: LibreSCRS", "Label: LibreSCRS", f"Suite: {suite}", f"Codename: {suite}",
            f"Date: {rfc(now)}", f"Valid-Until: {rfc(now + valid_days * 86400)}",
            "Architectures: amd64 all", "Components: main", "Acquire-By-Hash: yes",
            "Description: LibreSCRS packages"]
    body = ["SHA256:"] + [f" {sha256(p)} {os.path.getsize(p):>10} {rel}" for rel, p in sorted(files.items())]
    return "\n".join(head + body) + "\n"


def tag_key(tag):
    return (vkey(tag) or (0, 0, 0), tag)


def scan_inputs(indir):
    """[(repo, tag, dir)] for every <in>/<Repo>/<tag>, the oldest tag first."""
    found = []
    for repo, _, _ in REPOS:
        rd = os.path.join(indir, repo)
        if not os.path.isdir(rd):
            continue
        for tag in sorted(os.listdir(rd), key=tag_key):
            d = os.path.join(rd, tag)
            if os.path.isdir(d):
                found.append((repo, tag, d))
    return found


def index_tool():
    return tool("PKG_REPO_INDEX", "pkg-repo-index.sh")


def slug_of(name):
    """(stem, slug) of <stem>.<slug>.<deb|rpm>."""
    base = name.rsplit(".", 1)[0]
    stem, _, slug = base.rpartition(".")
    return stem, slug


def put(src, dst):
    """Copy src to dst with the fixed mtime; False when dst holds other bytes."""
    if os.path.exists(dst):
        return sha256(src) == sha256(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    os.utime(dst, (FIXED_MTIME, FIXED_MTIME))
    return True


def deb_fields(indir):
    p = run(index_tool() + ["fields", indir])
    sys.stderr.write(p.stderr)
    if p.returncode != 0:
        raise Cannot(f"pkg-repo-index.sh fields failed (rc {p.returncode})")
    fields = {}
    for line in p.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 4:
            raise Cannot(f"unreadable fields row: {line!r}")
        fields[os.path.normpath(parts[0])] = parts[1:]
    return fields


def cmd_assemble(a):
    out = os.path.abspath(a.out)
    indir = os.path.abspath(a.in_)
    bad = []
    try:
        if not os.path.isdir(indir):
            raise Cannot(f"--in {indir} is not a directory")
        cert = os.path.join(HERE, "..", "keys", a.keyset + ".asc")
        if not os.path.isfile(cert):
            raise Cannot(f"no certificate for key set '{a.keyset}' ({cert})")
        if os.path.exists(out) and os.listdir(out):
            raise Cannot(f"--out {out} is not empty")
        prev = prev_mirror(a.prev)
        inputs = scan_inputs(indir)
        if not inputs:
            raise Cannot(f"no release directory under {indir}")
        pk = [d for r, t, d in inputs if r == "packages"]
        keys_file = os.path.join(pk[-1], "KEYS") if pk else ""
        if not os.path.isfile(keys_file):
            raise Cannot("no KEYS in the newest packages release (<in>/packages/<tag>/KEYS)")

        fields = deb_fields(indir) if any(n.endswith(".deb") for _, _, d in inputs for n in os.listdir(d)) else {}
        os.makedirs(out, exist_ok=True)
        deb_aliases, rpm_aliases = {}, {}
        codenames, slugs = set(), set()
        for repo, tag, d in inputs:
            for name in sorted(os.listdir(d)):
                src = os.path.join(d, name)
                if name.endswith(".deb"):
                    slug = slug_of(name)[1]
                    if slug not in DEB_SLUGS:
                        bad.append(f"{repo} {tag}: {name}: '{slug}' is not a deb slug")
                        continue
                    codename, suffix = DEB_SLUGS[slug]
                    pkg, ver, arch = fields[os.path.normpath(os.path.relpath(src, indir))]
                    if not ver.endswith(suffix):
                        bad.append(f"{repo} {tag}: {name}: Version {ver} does not end in {suffix} ({slug})")
                        continue
                    if arch not in ("amd64", "all"):
                        bad.append(f"{repo} {tag}: {name}: Architecture {arch} is not amd64 or all")
                        continue
                    ver = ver.split(":", 1)[-1].replace("~", ".")
                    dst = os.path.join(out, "deb", "pool", codename, f"{pkg}_{ver}_{arch}.deb")
                    if not put(src, dst):
                        bad.append(f"{repo} {tag}: {name}: {os.path.basename(dst)} already holds other bytes")
                        continue
                    codenames.add(codename)
                    if repo == "packages" and pkg == KEYRING_DEB:
                        deb_aliases[codename] = src
                elif name.endswith(".rpm"):
                    stem, slug = slug_of(name)
                    if slug not in RPM_SLUGS:
                        bad.append(f"{repo} {tag}: {name}: '{slug}' is not an rpm slug")
                        continue
                    dst = os.path.join(out, "rpm", slug, stem + ".rpm")
                    if not put(src, dst):
                        bad.append(f"{repo} {tag}: {name}: {os.path.basename(dst)} already holds other bytes")
                        continue
                    slugs.add(slug)
                    if repo == "packages" and KEYRING_RPM.match(stem):
                        rpm_aliases[slug] = src
        for codename in sorted(c for _, (c, _) in DEB_SLUGS.items()):
            if codename not in deb_aliases:
                bad.append(f"packages: no {KEYRING_DEB} for {codename}")
        for slug in RPM_ALIASES.values():
            if slug not in rpm_aliases:
                bad.append(f"packages: no librescrs-release for {slug}")
        if bad:
            for b in bad:
                print(f"::error::{b}")
            return 1
        for codename, src in deb_aliases.items():
            put(src, os.path.join(out, f"{KEYRING_DEB}-{codename}.deb"))
        for alias, slug in RPM_ALIASES.items():
            put(rpm_aliases[slug], os.path.join(out, alias))

        for codename in sorted(codenames):
            deb_index = run(index_tool() + ["deb", out, codename])
            sys.stdout.write(deb_index.stdout)
            sys.stderr.write(deb_index.stderr)
            if deb_index.returncode != 0:
                raise Cannot(f"pkg-repo-index.sh deb {codename} failed (rc {deb_index.returncode})")
            base = os.path.join(out, "deb", "dists", codename)
            files = {}
            for n in ("Packages", "Packages.xz"):
                rel_ = f"main/binary-amd64/{n}"
                path = os.path.join(base, rel_)
                files[rel_] = path
                h = os.path.join(base, "main/binary-amd64/by-hash/SHA256", sha256(path))
                os.makedirs(os.path.dirname(h), exist_ok=True)
                shutil.copyfile(path, h)
            with open(os.path.join(base, "Release"), "w") as f:
                f.write(release_file(codename, files, a.now, a.valid_days))
        # The revision of an rpm-md is a number of the content, so it changes
        # when the packages do and never otherwise.
        for slug in sorted(slugs):
            d = os.path.join(out, "rpm", slug)
            digest = hashlib.sha256("".join(sorted(sha256(os.path.join(d, n)) for n in os.listdir(d))).encode())
            env = dict(os.environ, PKG_REPO_REVISION=str(int(digest.hexdigest()[:8], 16)))
            p = run(index_tool() + ["rpm", out, slug], env=env)
            sys.stdout.write(p.stdout)
            sys.stderr.write(p.stderr)
            if p.returncode != 0:
                raise Cannot(f"pkg-repo-index.sh rpm {slug} failed (rc {p.returncode})")
            shutil.copyfile(cert, os.path.join(d, "repodata", "repomd.xml.key"))
        if prev:
            carry_prev(prev, out, sorted(codenames), sorted(slugs))
        shutil.copyfile(cert, os.path.join(out, "KEY.asc"))
        shutil.copyfile(keys_file, os.path.join(out, "KEYS"))
        write_index_html(out, sorted(codenames), sorted(slugs))
    except Cannot as e:
        print(f"pkg-repo: {e} -- cannot judge", file=sys.stderr)
        return 2
    except Exception as e:  # nothing unexpected is a pass, and none is a finding
        print(f"::error::assemble: unexpected {type(e).__name__}: {e} -- cannot judge")
        return 2
    return 0


def prev_mirror(path):
    """The directory of a fetch-prev mirror to merge, or "" when there is none.

    Absent, empty and EMPTY (fetch-prev found no published generation) merge
    nothing. Anything else must look like a mirror: a directory that holds
    neither is not one, and publishing without it would silently drop a
    generation.
    """
    if not path or not os.path.isdir(path) or not os.listdir(path):
        return ""
    if os.path.isfile(os.path.join(path, "EMPTY")):
        return ""
    if not (os.path.isdir(os.path.join(path, "deb")) or os.path.isdir(os.path.join(path, "rpm"))):
        raise Cannot(f"--prev {path} is neither a fetch-prev mirror nor empty")
    return os.path.abspath(path)


def carry_prev(prev, out, codenames, slugs):
    """Add to the new tree what only the previous one has, for the codenames
    and slugs the new tree has.

    Done after indexing, never before: apt-ftparchive and createrepo_c index
    whatever sits in the pool, and a carried package must stay out of the new
    index or it would be carried again forever. The new tree wins a name both
    hold (a by-hash or repodata name is a hash of its content, so a clash
    there is the same bytes); the current repomd.xml and its signature are
    never taken from the old one.
    """
    def walk(sub, keep):
        base = os.path.join(prev, sub)
        for dp, _, fs in os.walk(base):
            for n in sorted(fs):
                rel_ = os.path.relpath(os.path.join(dp, n), prev)
                if keep(rel_):
                    yield rel_

    wanted = []
    for c in codenames:
        wanted += list(walk(f"deb/dists/{c}", lambda r: "/by-hash/" in r))
        wanted += list(walk(f"deb/pool/{c}", lambda r: r.endswith(".deb")))
    for s in slugs:
        wanted += list(walk(f"rpm/{s}", lambda r, s=s: (
            r.endswith(".rpm") and os.path.dirname(r) == f"rpm/{s}")
            or (os.path.dirname(r) == f"rpm/{s}/repodata"
                and not os.path.basename(r).startswith("repomd.xml"))))
    carried = 0
    for rel_ in wanted:
        dst = os.path.join(out, rel_)
        if os.path.exists(dst):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(os.path.join(prev, rel_), dst)
        os.utime(dst, (FIXED_MTIME, FIXED_MTIME))
        carried += 1
    print(f"pkg-repo: carried {carried} files of the previous generation")


# ------------------------------------------------------------- fetch-prev --
class Finding(Exception):
    """A bad signature, a bad hash, a name outside its place: exit 1."""


class NotFound(Exception):
    """HTTP 404, or a file the local tree does not hold; the text says which."""


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "libreSCRS-pkg-repo"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise NotFound("HTTP 404")
        raise Cannot(f"{url}: HTTP {e.code}")
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Cannot(f"{url}: {e}")
    except Exception as e:  # http.client.HTTPException and the like
        raise Cannot(f"{url}: {e}")


def keyset_fprs(keyset):
    """(certificate path, {name: fingerprint}) of a key set."""
    keys = os.path.join(HERE, "..", "keys")
    cert, env = os.path.join(keys, keyset + ".asc"), os.path.join(keys, keyset + ".env")
    if not os.path.isfile(cert) or not os.path.isfile(env):
        raise Cannot(f"no certificate or fingerprints for key set '{keyset}' ({keys})")
    fprs = {}
    with open(env) as f:
        for line in f:
            k, _, v = line.strip().partition("=")
            if re.fullmatch(r"[0-9A-F]{40}", v):
                fprs[k] = v
    return cert, fprs


def keyset_env(keyset):
    """(certificate path, S_IDX_FPR) of a key set."""
    cert, fprs = keyset_fprs(keyset)
    if "S_IDX_FPR" not in fprs:
        raise Cannot(f"{keyset}.env: no S_IDX_FPR")
    return cert, fprs["S_IDX_FPR"]


class Signer:
    """gpgv against the key set's certificate; a signature counts only when
    the key that made it is exactly S_IDX_FPR (the first VALIDSIG field)."""

    def __init__(self, keyset, home):
        self.cert, self.fpr = keyset_env(keyset)
        self.home = home
        self.env = dict(os.environ, GNUPGHOME=home, LC_ALL="C", LANGUAGE="")
        self.ring = os.path.join(home, "idx.gpg")  # an absolute file: a pipe does not work with gpgv
        p = run(["gpg", "--batch", "--dearmor", "--output", self.ring, self.cert], env=self.env)
        if p.returncode != 0 or not os.path.getsize(self.ring):
            raise Cannot(f"cannot dearmor {self.cert}: {p.stderr.strip()}")

    def verify(self, sig, data=None, output=None, what=""):
        # The signed text is read from stdout, never from --output FILE:
        # gpgv 2.5.22 verifies and then writes no such file. Status lines
        # go to stderr beside gpgv's own messages, told apart by prefix.
        argv = ["gpgv", "--status-fd", "2", "--keyring", self.ring]
        if output:
            argv += ["--output", "-"]
        p = run(argv + [sig] + ([data] if data else []), env=self.env, text=False)
        err = p.stderr.decode("utf-8", "replace").splitlines()
        status = [l for l in err if l.startswith("[GNUPG:] ")]
        said = [l for l in err if not l.startswith("[GNUPG:] ")]
        valid = [l.split()[2] for l in status if l.startswith("[GNUPG:] VALIDSIG ")]
        if p.returncode != 0 or any(l.startswith("[GNUPG:] BADSIG ") for l in status) or not valid:
            raise Finding(f"{what}: the signature does not verify ({said[-1:] or 'no VALIDSIG'})")
        if valid[0] != self.fpr:
            raise Finding(f"{what}: signed by {valid[0]}, not by the index signer {self.fpr}")
        if output:
            with open(output, "wb") as f:
                f.write(p.stdout)


class Mirror:
    def __init__(self, url, root):
        self.url, self.root = url.rstrip("/"), root
        self.count = 0

    def get(self, rel_):
        return http_get(f"{self.url}/{rel_}")

    def need(self, rel_):
        """get for a file a signed index names or the tree requires: absent is a finding."""
        try:
            return self.get(rel_)
        except NotFound as e:
            raise Finding(f"{rel_}: named by a signed index (or required) but {e}")

    def place(self, rel_):
        norm = os.path.normpath(rel_)
        if norm.startswith("..") or os.path.isabs(norm):
            raise Finding(f"{rel_}: a name outside the tree")
        return os.path.join(self.root, norm)

    def put(self, rel_, data):
        dst = self.place(rel_)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(data)
        os.utime(dst, (FIXED_MTIME, FIXED_MTIME))
        self.count += 1
        return dst

    def fetch(self, rel_, algo="sha256", digest=None, size=None):
        """get + hash check + keep. A name that is not in the tree's own
        place (inside `prefix` of the caller) is judged by the caller."""
        data = self.need(rel_)
        if size is not None and len(data) != size:
            raise Finding(f"{rel_}: {len(data)} bytes, the index says {size}")
        if digest is not None:
            try:
                h = hashlib.new(algo, data).hexdigest()
            except ValueError:
                raise Finding(f"{rel_}: unknown checksum type {algo}")
            if h != digest.lower():
                raise Finding(f"{rel_}: {algo} {h} is not the {digest} the index names")
        return self.put(rel_, data)


class Tree(Mirror):
    """A local tree judged through the mirror's checks: read, never written."""

    def __init__(self, root):
        super().__init__("", root)
        self.real = os.path.realpath(root)

    def place(self, rel_):
        dst = super().place(rel_)
        if not os.path.realpath(dst).startswith(self.real + os.sep):
            raise Finding(f"{rel_}: resolves outside the tree")
        return dst

    def get(self, rel_):
        path = self.place(rel_)
        if not os.path.isfile(path):
            raise NotFound("missing from the tree")
        with open(path, "rb") as f:
            return f.read()

    def put(self, rel_, data):
        self.count += 1
        return self.place(rel_)


def inside(rel_, prefix):
    n = os.path.normpath(rel_)
    if not n.startswith(prefix.rstrip("/") + "/") or ".." in n.split("/"):
        raise Finding(f"{rel_}: not under {prefix}")
    return n


def parse_release(text):
    """[(sha256, size, path)] of the SHA256 section of a Release."""
    entries, in_sec = [], False
    for line in text.splitlines():
        if line.startswith("SHA256:"):
            in_sec = True
        elif in_sec and line.startswith(" "):
            f = line.split()
            if len(f) != 3 or not f[1].isdigit():
                raise Finding(f"unreadable Release line: {line!r}")
            entries.append((f[0], int(f[1]), f[2]))
        else:
            in_sec = False
    return entries


def parse_packages(text):
    """[(Filename, SHA256, Size)] of a Packages file."""
    found = []
    for stanza in re.split(r"\n\s*\n", text.strip()):
        fields = dict(l.split(": ", 1) for l in stanza.splitlines() if ": " in l and not l.startswith(" "))
        if not stanza.strip():
            continue
        if not all(k in fields for k in ("Filename", "SHA256", "Size")) or not fields["Size"].isdigit():
            raise Finding(f"a Packages stanza without Filename, SHA256 and Size: {stanza.splitlines()[0]!r}")
        found.append((fields["Filename"], fields["SHA256"], int(fields["Size"])))
    return found


def valid_until(text, now, what):
    """Valid-Until of a Release text must be later than now."""
    found = [l.split(":", 1)[1].strip() for l in text.splitlines() if l.startswith("Valid-Until:")]
    if len(found) != 1:
        raise Finding(f"{what}: {len(found)} Valid-Until fields, want exactly one")
    try:
        until = email.utils.parsedate_to_datetime(found[0])
    except (TypeError, ValueError):
        raise Finding(f"{what}: unreadable Valid-Until {found[0]!r}")
    if until.tzinfo is None:  # no zone, or -0000: .timestamp() would read it in the host's zone
        raise Finding(f"{what}: Valid-Until has no timezone ({found[0]})")
    until = until.timestamp()
    if until <= now:
        raise Finding(f"{what}: Valid-Until {found[0]} is not later than now ({now})")
    return until, found[0]


def fetch_deb(m, sg, codename, work, inrelease=None, now=None):
    """The signed chain of one codename; with sg None (a tree not yet signed)
    the chain of its Release alone. now judges Valid-Until. Returns the
    SHA256 of every package Packages names."""
    base = f"deb/dists/{codename}"
    if sg:
        what = f"{base}/InRelease"
        dst = m.put(what, m.need(what) if inrelease is None else inrelease)
        out = os.path.join(work, f"release-{codename}")
        sg.verify(dst, output=out, what=what)
        with open(out, "rb") as f:
            signed = f.read()
        text = signed.decode("utf-8")
    else:
        what = f"{base}/Release"
        text = m.need(what).decode("utf-8")
    entries = parse_release(text)
    if not entries:
        raise Finding(f"{what} names no file")
    names = [l.split(":", 1)[1].strip() for l in text.splitlines() if l.startswith("Codename:")]
    if names != [codename]:
        raise Finding(f"{what}: Codename {names or 'missing'}, want exactly {codename}")
    rel_path = m.put(f"{base}/Release", m.need(f"{base}/Release"))
    with open(rel_path, encoding="utf-8") as f:
        rel_text = f.read()
    if sg:
        sg.verify(m.put(f"{base}/Release.gpg", m.need(f"{base}/Release.gpg")), rel_path, what=f"{base}/Release.gpg")
        if sorted(parse_release(rel_text)) != sorted(entries):
            raise Finding(f"{base}/Release does not name what InRelease names")
        with open(rel_path, "rb") as f:
            if f.read() != signed:
                raise Finding(f"{base}/InRelease does not sign exactly the bytes of {base}/Release")
    if now is not None:
        valid_until(text, now, what)
        valid_until(rel_text, now, f"{base}/Release")
    packages = None
    for digest, size, path in entries:
        name = inside(f"{base}/{path}", base)
        dst = m.fetch(name, "sha256", digest, size)
        m.fetch(f"{os.path.dirname(name)}/by-hash/SHA256/{digest}", "sha256", digest, size)
        if path.endswith("/Packages"):
            packages = dst
    if packages is None:
        raise Finding(f"{base}/InRelease names no Packages")
    named = set()
    with open(packages, encoding="utf-8") as f:
        for filename, digest, size in parse_packages(f.read()):
            m.fetch(inside(f"deb/{filename}", f"deb/pool/{codename}"), "sha256", digest, size)
            named.add(digest.lower())
    return named


RPM_MD = "{http://linux.duke.edu/metadata/repo}"
RPM_COMMON = "{http://linux.duke.edu/metadata/common}"


def read_compressed(path):
    with open(path, "rb") as f:
        raw = f.read()
    if path.endswith(".zst"):
        p = run(["zstd", "-dc"], input=raw, text=False)
        if p.returncode != 0:
            raise Finding(f"{path}: not zstd data")
        return p.stdout
    try:
        if path.endswith(".gz"):
            return gzip.decompress(raw)
        if path.endswith(".xz"):
            return lzma.decompress(raw)
    except (OSError, EOFError, lzma.LZMAError) as e:
        raise Finding(f"{path}: {e}")
    return raw


def checksum_of(el, ns):
    c = el.find(f"{ns}checksum")
    if c is None or not c.text or not c.get("type"):
        raise Finding("an entry without a checksum")
    return {"sha": "sha1"}.get(c.get("type"), c.get("type")), c.text.strip()


def fetch_rpm(m, sg, slug, cert_bytes, required=False):
    """The signed chain of one slug (sg None: unsigned, the chain alone).
    Returns {path: sha256 or None} of every rpm primary names."""
    base = f"rpm/{slug}"
    try:
        repomd = m.get(f"{base}/repodata/repomd.xml")
    except NotFound as e:
        if required:
            raise Finding(f"{base}/repodata/repomd.xml: {e}")
        print(f"::warning::{slug}: no repomd.xml on the site, not mirrored")
        return {}
    md = m.put(f"{base}/repodata/repomd.xml", repomd)
    if sg:
        sg.verify(m.put(f"{base}/repodata/repomd.xml.asc", m.need(f"{base}/repodata/repomd.xml.asc")), md,
                  what=f"{base}/repodata/repomd.xml.asc")
    if m.need(f"{base}/repodata/repomd.xml.key") != cert_bytes:
        raise Finding(f"{base}/repodata/repomd.xml.key is not the key set's certificate")
    m.put(f"{base}/repodata/repomd.xml.key", cert_bytes)
    try:
        root = ET.fromstring(repomd)
    except ET.ParseError as e:
        raise Finding(f"{base}/repodata/repomd.xml: {e}")
    primary = None
    for data in root.findall(f"{RPM_MD}data"):
        loc = data.find(f"{RPM_MD}location")
        if loc is None or not loc.get("href"):
            raise Finding(f"{base}/repodata/repomd.xml: an entry without a location")
        algo, digest = checksum_of(data, RPM_MD)
        size = data.find(f"{RPM_MD}size")
        dst = m.fetch(inside(f"{base}/{loc.get('href')}", f"{base}/repodata"), algo, digest,
                      int(size.text) if size is not None and size.text and size.text.isdigit() else None)
        if data.get("type") == "primary":
            primary = dst
    if primary is None:
        raise Finding(f"{base}/repodata/repomd.xml names no primary")
    try:
        pkgs = ET.fromstring(read_compressed(primary)).findall(f"{RPM_COMMON}package")
    except ET.ParseError as e:
        raise Finding(f"{primary}: {e}")
    named = {}
    for pkg in pkgs:
        loc = pkg.find(f"{RPM_COMMON}location")
        if loc is None or not loc.get("href"):
            raise Finding(f"{primary}: a package without a location")
        algo, digest = checksum_of(pkg, RPM_COMMON)
        dst = m.fetch(inside(f"{base}/{loc.get('href')}", base), algo, digest)
        named[dst] = digest.lower() if algo == "sha256" else None
    return named


def check_aliases(m, named, any_index=False):
    """Every stable alias is a package its index names (named: codename ->
    the SHA256 set fetch_deb returns, slug -> fetch_rpm's map); m keeps each.
    An alias that is missing is a finding, as any file the tree requires.
    any_index: a release package alias may be a package any rpm index names
    -- a previous generation was built when another slug was its source. A
    keyring alias names its codename and stays bound to it."""
    for alias, where in ALIASES.items():
        data = m.need(alias)
        if any_index and where in RPM_ALIASES.values():
            pool = set().union(*(set(v.values()) for v in named.values() if isinstance(v, dict)))
            what = "any rpm index of the previous generation"
        else:
            pool = set(named[where].values()) if isinstance(named[where], dict) else named[where]
            what = f"the {where} index"
        if hashlib.sha256(data).hexdigest() not in pool:
            raise Finding(f"{alias}: not a package {what} names")
        m.put(alias, data)


def listed_slugs(m):
    """The rpm slugs the site's index.html links to. Unsigned: it only says
    where else to look; every index found there is judged by its signature
    as any other."""
    try:
        text = m.get("index.html").decode("utf-8", "replace")
    except NotFound:
        return []
    return sorted(set(re.findall(r'href="rpm/([a-z0-9]+)/repodata/repomd\.xml"', text)))


def cmd_fetch_prev(a):
    out = os.path.abspath(a.out)
    home = None
    staging = out + ".partial"
    try:
        if os.path.exists(out) and os.listdir(out):
            raise Cannot(f"--out {out} is not empty")
        if not re.match(r"^https?://", a.url):
            raise Cannot(f"--url {a.url} is not an http(s) URL")
        shutil.rmtree(staging, ignore_errors=True)
        m = Mirror(a.url, staging)
        first = f"deb/dists/{CODENAMES[0]}/InRelease"
        try:
            inreleases = {CODENAMES[0]: m.get(first)}
        except NotFound:
            os.makedirs(out, exist_ok=True)
            with open(os.path.join(out, "EMPTY"), "w") as f:
                f.write(f"{a.url}/{first} is HTTP 404: no published generation\n")
            print(f"pkg-repo: no published generation at {a.url} (EMPTY)")
            return 0
        # The key set only now: nothing published needs no key to judge it.
        home = tempfile.mkdtemp(dir=os.environ.get("TMPDIR", "/var/tmp"), prefix="lg.")
        sg = Signer(a.keyset, home)
        with open(sg.cert, "rb") as f:
            cert_bytes = f.read()
        os.makedirs(staging)
        for c in CODENAMES[1:]:
            try:
                inreleases[c] = m.get(f"deb/dists/{c}/InRelease")
            except NotFound:
                raise Finding(f"deb/dists/{c}/InRelease is missing while {CODENAMES[0]} is published")
        named = {}
        for c in CODENAMES:
            named[c] = fetch_deb(m, sg, c, home, inreleases[c])
        for slug in RPM_SLUGS:
            named[slug] = fetch_rpm(m, sg, slug, cert_bytes)
        # A slug this code no longer builds may still be the source of the
        # release package alias the previous generation serves: its signed
        # index is judged, and only the alias is kept.
        retired = [slug for slug in listed_slugs(m) if slug not in RPM_SLUGS]
        for slug in retired:
            named[slug] = fetch_rpm(m, sg, slug, cert_bytes, required=True)
        if m.need("KEY.asc") != cert_bytes:
            raise Finding("KEY.asc is not the key set's certificate")
        m.put("KEY.asc", cert_bytes)
        check_aliases(m, named, any_index=True)
        m.put("KEYS", m.need("KEYS"))  # unsigned, as the site serves it
        for slug in retired:
            shutil.rmtree(os.path.join(staging, "rpm", slug), ignore_errors=True)
        os.makedirs(out, exist_ok=True)
        os.rmdir(out)
        os.rename(staging, out)
        print(f"pkg-repo: mirrored {m.count} verified files of the previous generation")
        return 0
    except Finding as e:
        print(f"::error::{e}")
        return 1
    except Cannot as e:
        print(f"pkg-repo: {e} -- cannot judge", file=sys.stderr)
        return 2
    except Exception as e:  # nothing unexpected is a pass, and none is a finding
        print(f"::error::fetch-prev: unexpected {type(e).__name__}: {e} -- cannot judge")
        return 2
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        if home:
            shutil.rmtree(home, ignore_errors=True)


# ------------------------------------------------- sign-index, verify-tree --


def gpg_home():
    home = tempfile.mkdtemp(dir=os.environ.get("TMPDIR", "/var/tmp"), prefix="lg.")
    os.chmod(home, 0o700)
    return home


def drop_home(home):
    """Stop the home's agent and remove it; called from finally, so it never raises."""
    if not home:
        return
    try:
        subprocess.run(["gpgconf", "--kill", "all"], env=dict(os.environ, GNUPGHOME=home), capture_output=True)
    except OSError:
        pass  # no gpgconf: no agent of this home was started by it either
    shutil.rmtree(home, ignore_errors=True)


def cmd_sign_index(a):
    tree_ = os.path.abspath(a.tree)
    home, staged = None, []
    try:
        if not os.path.isdir(tree_):
            raise Cannot(f"--tree {tree_} is not a directory")
        key = a.key
        if not key:
            if a.keyset != "rehearsal":
                raise Cannot(f"--keyset {a.keyset} needs --key (the armored index subkey)")
            key = os.path.join(HERE, "..", "keys", "rehearsal.sec.asc")
        if not os.path.isfile(key) or not os.path.getsize(key):
            raise Cannot(f"no secret key at {key}")
        _, fprs = keyset_fprs(a.keyset)
        fpr = keyset_env(a.keyset)[1]
        jobs = []
        for c in CODENAMES:
            r = os.path.join(tree_, "deb", "dists", c, "Release")
            if os.path.isfile(r):
                jobs += [(r, "InRelease", ["--clearsign"]), (r, "Release.gpg", ["--detach-sign"])]
        for slug in RPM_SLUGS:
            md = os.path.join(tree_, "rpm", slug, "repodata", "repomd.xml")
            if os.path.isfile(md):
                jobs.append((md, "repomd.xml.asc", ["--detach-sign", "--armor"]))
        if not jobs:
            raise Cannot(f"{tree_} holds no Release and no repomd.xml to sign")

        home = gpg_home()
        env = dict(os.environ, GNUPGHOME=home, LC_ALL="C", LANGUAGE="")
        g = ["gpg", "--batch", "--yes", "--no-tty", "--pinentry-mode", "loopback", "--passphrase", ""]
        p = run(g + ["--import", key], env=env)
        if p.returncode != 0:
            raise Cannot(f"the key at {key} does not import: {p.stderr.strip()}")
        p = run(g + ["--list-secret-keys", "--with-colons"], env=env)
        held = {l.split(":")[9] for l in p.stdout.splitlines() if l.startswith("fpr:")}
        if not held or not held <= set(fprs.values()):
            raise Cannot(f"the key at {key} holds keys outside the key set '{a.keyset}': {sorted(held - set(fprs.values()))}")
        sg = Signer(a.keyset, home)
        for src, name, flags in jobs:
            dst = os.path.join(os.path.dirname(src), name)
            what = os.path.relpath(dst, tree_)
            staged.append((dst + ".new", dst))
            p = run(g + ["--local-user", fpr + "!", "--digest-algo", "SHA512"] + flags
                    + ["--output", dst + ".new", src], env=env)
            if p.returncode != 0:
                raise Finding(f"{what}: gpg cannot sign with the index subkey {fpr}: {' / '.join(p.stderr.strip().splitlines())}")
            if name == "InRelease":
                text = os.path.join(home, "signed-text")
                sg.verify(dst + ".new", output=text, what=what)
                with open(text, "rb") as f, open(src, "rb") as r:
                    if f.read() != r.read():
                        raise Finding(f"{what}: the clearsigned text is not the bytes of Release"
                                      " (gpg strips trailing whitespace)")
            else:
                sg.verify(dst + ".new", src, what=what)
        for new, dst in staged:
            os.replace(new, dst)
        print(f"pkg-repo: signed {len(staged)} index signatures with {fpr}")
        return 0
    except Finding as e:
        print(f"::error::{e}")
        return 1
    except Cannot as e:
        print(f"pkg-repo: {e} -- cannot judge", file=sys.stderr)
        return 2
    except Exception as e:  # nothing unexpected is a pass, and none is a finding
        print(f"::error::sign-index: unexpected {type(e).__name__}: {e} -- cannot judge")
        return 2
    finally:
        for new, _ in staged:  # a failure writes none of them
            if os.path.isfile(new):
                os.unlink(new)
        drop_home(home)


def cmd_verify_tree(a):
    tree_ = os.path.abspath(a.tree)
    home = stage = None
    try:
        if not os.path.isdir(tree_):
            raise Cannot(f"--tree {tree_} is not a directory")
        cert, _ = keyset_env(a.keyset)
        with open(cert, "rb") as f:
            cert_bytes = f.read()
        home = None if a.unsigned else gpg_home()
        sg = None if a.unsigned else Signer(a.keyset, home)
        m = Tree(tree_)
        named = {}
        for c in CODENAMES:
            named[c] = fetch_deb(m, sg, c, home, now=int(time.time()) if a.now is None else a.now)
        for slug in RPM_SLUGS:
            named[slug] = fetch_rpm(m, sg, slug, cert_bytes, required=True)
        if m.need("KEY.asc") != cert_bytes:
            raise Finding("KEY.asc is not the key set's certificate")
        check_aliases(m, named)
        if a.unsigned:
            print(f"pkg-repo: the hash chain of {m.count} files holds (unsigned: no signature judged)")
            return 0
        # Every rpm primary names, wherever it lies, and every rpm at the top of
        # the slug (a carried one no current index names); pkg-sign.sh takes the
        # slug from <stem>.<slug>.rpm.
        stage = tempfile.mkdtemp(dir=os.environ.get("TMPDIR", "/var/tmp"), prefix="vt-rpm.")
        for slug in RPM_SLUGS:
            d = os.path.join(tree_, "rpm", slug)
            paths = set(named[slug]) | {os.path.join(d, n) for n in os.listdir(d) if n.endswith(".rpm")}
            for path in sorted(paths, key=os.path.realpath):
                link = os.path.join(stage, f"{os.path.basename(path)[:-4]}.{slug}.rpm")
                if os.path.lexists(link):
                    if os.path.realpath(os.readlink(link)) == os.path.realpath(path):
                        continue
                    raise Cannot(f"two rpms of {slug} share the name {os.path.basename(path)}")
                os.symlink(os.path.realpath(path), link)
        rc = verify_rpms(stage, a.keyset, "tree")
        if rc == 0:
            print(f"pkg-repo: the tree holds: {m.count} files, every index signed by the index subkey")
        return rc
    except Finding as e:
        print(f"::error::{e}")
        return 1
    except Cannot as e:
        print(f"pkg-repo: {e} -- cannot judge", file=sys.stderr)
        return 2
    except Exception as e:  # nothing unexpected is a pass, and none is a finding
        print(f"::error::verify-tree: unexpected {type(e).__name__}: {e} -- cannot judge")
        return 2
    finally:
        if stage:
            shutil.rmtree(stage, ignore_errors=True)
        drop_home(home)


def cmd_watch(a):
    home = None
    try:
        if not re.match(r"^https?://", a.url):
            raise Cannot(f"--url {a.url} is not an http(s) URL")
        if a.min_days < 0:
            raise Cannot("--min-days must not be negative")
        env_now = os.environ.get("PKG_REPO_NOW", "")
        if env_now and not env_now.isdigit():
            raise Cannot(f"PKG_REPO_NOW={env_now!r} is not epoch seconds")
        now = int(env_now) if env_now else int(time.time())
        horizon = now + a.min_days * 86400
        home = gpg_home()
        sg = Signer(a.keyset, home)
        m = Mirror(a.url, home)
        texts = {}
        for c in CODENAMES:
            what = f"deb/dists/{c}/InRelease"
            try:
                data = m.get(what)
            except NotFound:
                if c != CODENAMES[0]:
                    raise Finding(f"{what} is missing while {CODENAMES[0]} is published")
                # Green only before the first release, by fetch-releases' rule.
                released = released_code()
                if released:
                    raise Finding(f"{a.url}/{what} is HTTP 404, but {', '.join(released)} released"
                                  " -- the published repository is gone")
                print(f"pkg-repo: {a.url}/{what} is HTTP 404: not yet published (no code repository released)")
                return 0
            src, out = os.path.join(home, f"in-{c}"), os.path.join(home, f"text-{c}")
            with open(src, "wb") as f:
                f.write(data)
            sg.verify(src, output=out, what=what)
            with open(out, encoding="utf-8") as f:
                texts[c] = f.read()
            names = [l.split(":", 1)[1].strip() for l in texts[c].splitlines() if l.startswith("Codename:")]
            if names != [c]:
                raise Finding(f"{what}: Codename {names or 'missing'}, want exactly {c}")
        for c in CODENAMES:
            what = f"deb/dists/{c}/InRelease"
            until, raw = valid_until(texts[c], now, what)
            if until <= horizon:
                raise Finding(f"{what}: Valid-Until {raw} is less than {a.min_days} days away"
                              " -- the scheduled re-sign has not run; dispatch publish.yml")
            print(f"pkg-repo: {what} valid until {raw} (more than {a.min_days} days ahead)")
        return 0
    except Finding as e:
        print(f"::error::{e}")
        return 1
    except Cannot as e:
        print(f"pkg-repo: {e} -- cannot judge", file=sys.stderr)
        return 2
    except Exception as e:  # nothing unexpected is a pass, and none is a finding
        print(f"::error::watch: unexpected {type(e).__name__}: {e} -- cannot judge")
        return 2
    finally:
        drop_home(home)


def write_index_html(out, codenames, slugs):
    items = [f'<li><a href="deb/dists/{c}/Release">deb {c}</a></li>' for c in codenames]
    items += [f'<li><a href="rpm/{s}/repodata/repomd.xml">rpm {s}</a></li>' for s in slugs]
    items += ['<li><a href="KEY.asc">KEY.asc</a></li>', '<li><a href="KEYS">KEYS</a></li>']
    with open(os.path.join(out, "index.html"), "w") as f:
        f.write('<!doctype html>\n<html><head><meta charset="utf-8"><title>LibreSCRS packages</title></head>\n'
                "<body><h1>LibreSCRS packages</h1>\n<ul>\n" + "\n".join(items) + "\n</ul></body></html>\n")


def main(argv):
    ap = argparse.ArgumentParser(prog="pkg-repo.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select")
    s.add_argument("--releases", required=True, help="gh api releases JSON file, or - for stdin")
    s.add_argument("--keep", type=int, required=True)
    s.add_argument("--min", required=True)
    s.set_defaults(fn=cmd_select)
    f = sub.add_parser("fetch-releases")
    f.add_argument("--out", required=True)
    f.add_argument("--mode", choices=("publish", "rehearse"), required=True)
    f.add_argument("--allow-none", action="store_true",
                   help="publish: no repository released yet is <out>/NONE and rc 0, not a finding")
    f.set_defaults(fn=cmd_fetch)
    m = sub.add_parser("assemble")
    m.add_argument("--in", dest="in_", required=True, help="a fetch-releases directory")
    m.add_argument("--prev", default="", help="a fetch-prev mirror to carry one more generation (empty, absent or EMPTY: nothing)")
    m.add_argument("--out", required=True)
    m.add_argument("--now", type=int, required=True, help="epoch seconds")
    m.add_argument("--valid-days", type=int, default=30)
    m.add_argument("--keyset", choices=("rehearsal", "package-signing"), required=True)
    m.set_defaults(fn=cmd_assemble)
    v = sub.add_parser("fetch-prev")
    v.add_argument("--url", required=True, help="base URL of the published site")
    v.add_argument("--keyset", choices=("rehearsal", "package-signing"), required=True)
    v.add_argument("--out", required=True)
    v.set_defaults(fn=cmd_fetch_prev)
    g = sub.add_parser("sign-index")
    g.add_argument("--tree", required=True)
    g.add_argument("--keyset", choices=("rehearsal", "package-signing"), required=True)
    g.add_argument("--key", default="", help="the armored secret index subkey (rehearsal: keys/rehearsal.sec.asc)")
    g.set_defaults(fn=cmd_sign_index)
    t = sub.add_parser("verify-tree")
    t.add_argument("--tree", required=True)
    t.add_argument("--keyset", choices=("rehearsal", "package-signing"), required=True)
    t.add_argument("--unsigned", action="store_true", help="the hash chain only, of a tree not yet signed")
    t.add_argument("--now", type=int, default=None, help="epoch seconds (default: the clock)")
    t.set_defaults(fn=cmd_verify_tree)
    w = sub.add_parser("watch")
    w.add_argument("--url", required=True, help="base URL of the published site")
    w.add_argument("--keyset", choices=("rehearsal", "package-signing"), required=True)
    w.add_argument("--min-days", type=int, required=True, help="Valid-Until must lie more than this many days ahead")
    w.set_defaults(fn=cmd_watch)
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
