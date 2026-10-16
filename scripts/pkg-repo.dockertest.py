#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (the index tools run in the distributions' own images)
"""Self-test for pkg-repo.py assemble against real containers: .deb built in the
debian13 image, rpms built in the fedora43, fedora44 and opensusetw images and
signed with the public rehearsal key (pkg-sign.sh --keyset rehearsal).

Cases: the structure of the tree; a ~ubuntu26.04 package in the trixie set is
red; no KEYS and a --prev that is no mirror are "cannot judge"; two assembles
seven days apart differ only in Release Date and Valid-Until; --prev carries the
previous generation's by-hash, repodata and pool files one more generation;
sign-index and verify-tree over the real tree, and an unsigned rpm under a
correctly signed index is red."""
import email.utils
import filecmp
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "pkg-repo.py")
NOW = 1792000000
cases = reds = fails = 0
work = tempfile.mkdtemp(prefix="pkg-repo-dt.", dir=os.environ.get("TMPDIR", "/var/tmp"))
OWN = f"{os.getuid()}:{os.getgid()}"


def sh(*argv, **kw):
    return subprocess.run(list(argv), capture_output=True, text=True, **kw)


def image(slug):
    p = sh(os.path.join(HERE, "pkg-images"), "get", slug)
    if p.returncode:
        print(f"FATAL: no image for {slug}: {p.stderr}")
        sys.exit(2)
    return p.stdout.strip()


def dock(img, script, mount, env=()):
    name = f"pkg-repo-dt-{os.getpid()}-{abs(hash(script)) % 100000}"
    argv = ["docker", "run", "--rm", "--name", name, "-v", f"{mount}:/w", "-e", f"OWN={OWN}"]
    for k, v in env:
        argv += ["-e", f"{k}={v}"]
    p = sh(*argv, img, "bash", "-c", script)
    sh("docker", "rm", "-f", name)
    if p.returncode:
        print(f"FATAL: fixture step failed -- cannot measure\n{p.stdout}{p.stderr}")
        sys.exit(2)


def check(name, ok, red=False, detail=""):
    global cases, reds, fails
    cases += 1
    reds += 1 if red else 0
    if not ok:
        fails += 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"\n      {detail}" if detail and not ok else ""))


def assemble(indir, out, now=NOW, prev=None):
    argv = [sys.executable, "-I", TOOL, "assemble", "--in", indir, "--out", out, "--now", str(now),
            "--valid-days", "30", "--keyset", "rehearsal"]
    if prev:
        argv += ["--prev", prev]
    return sh(*argv)


def read(*p):
    with open(os.path.join(*p)) as f:
        return f.read()


try:
    # ---- fixture -----------------------------------------------------------
    fx = os.path.join(work, "fx")
    os.makedirs(os.path.join(fx, "debs"))
    os.makedirs(os.path.join(fx, "rpms"))
    dock(image("debian13"), r'''
set -eu
mk() {  # mk PACKAGE ARCH VERSION SLUG
    d=$(mktemp -d); mkdir -p $d/DEBIAN
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@invalid>\nDescription: fixture\n' "$1" "$3" "$2" >$d/DEBIAN/control
    dpkg-deb --root-owner-group -Zxz --build $d /w/debs/tmp.deb >/dev/null
    stem="$1_${3//\~/.}_$2"
    mv /w/debs/tmp.deb "/w/debs/$stem.$4.deb"
}
mk liblibrescrs5 amd64 5.0.0-1~deb13 debian13
mk liblibrescrs5 amd64 5.0.0-1~ubuntu26.04 ubuntu2604
mk librescrs-archive-keyring all 1.0.0-1~deb13 debian13
mk librescrs-archive-keyring all 1.0.0-1~ubuntu26.04 ubuntu2604
chown -R $OWN /w''', fx)
    spec = r'''
set -eu
case "$PM" in dnf) dnf -y -q install rpm-build >/dev/null ;; zypper) zypper -n -q install rpm-build >/dev/null ;; esac
mk() {
    mkdir -p /b/SPECS
    printf 'Name: %s\nVersion: %s\nRelease: 1%%{?dist}\nSummary: fixture\nLicense: MIT\nBuildArch: noarch\n%%description\nfixture\n%%files\n' "$1" "$2" >/b/SPECS/$1.spec
    rpmbuild --define "_topdir /b" --define "dist .$SLUG" -bb /b/SPECS/$1.spec >/dev/null 2>&1
    f=$(ls /b/RPMS/noarch/$1-*.rpm); n=$(basename $f .rpm)
    cp $f /w/rpms/$n.$SLUG.rpm; rm -rf /b/RPMS
}
mk libls 5.0.0
[ "$SLUG" = fedora44 ] || mk librescrs-release 1.0.0
chown -R $OWN /w'''
    for slug, pm in (("fedora43", "dnf"), ("fedora44", "dnf"), ("opensusetw", "zypper")):
        dock(image(slug), spec, fx, (("SLUG", slug), ("PM", pm)))
    UNSIGNED = "libls-5.0.0-1.fedora44.noarch.fedora44.rpm"
    os.makedirs(os.path.join(fx, "unsigned"))
    shutil.copyfile(os.path.join(fx, "rpms", UNSIGNED), os.path.join(fx, "unsigned", UNSIGNED))
    p = sh(os.path.join(HERE, "pkg-sign.sh"), "--dir", os.path.join(fx, "rpms"), "--keyset", "rehearsal")
    if p.returncode:
        print(f"FATAL: cannot sign the fixture -- cannot measure\n{p.stdout}{p.stderr}")
        sys.exit(2)

    def layout(name, keys=True, swap_ubuntu_into_trixie=False):
        root = os.path.join(work, name)
        lm = os.path.join(root, "LibreMiddleware", "5.0.0")
        pk = os.path.join(root, "packages", "1.0.0")
        os.makedirs(lm)
        os.makedirs(pk)
        for n in os.listdir(os.path.join(fx, "debs")):
            dst = pk if "archive-keyring" in n else lm
            shutil.copyfile(os.path.join(fx, "debs", n), os.path.join(dst, n))
        for n in os.listdir(os.path.join(fx, "rpms")):
            dst = pk if "librescrs-release" in n else lm
            shutil.copyfile(os.path.join(fx, "rpms", n), os.path.join(dst, n))
        if keys:
            with open(os.path.join(pk, "KEYS"), "w") as f:
                f.write("fixture KEYS\n")
        if swap_ubuntu_into_trixie:  # an ubuntu build under the debian13 slug
            shutil.copyfile(os.path.join(fx, "debs", "liblibrescrs5_5.0.0-1.ubuntu26.04_amd64.ubuntu2604.deb"),
                            os.path.join(lm, "liblibrescrs5_5.0.0-1.ubuntu26.04_amd64.debian13.deb"))
        return root

    good = layout("in-good")

    # ---- 1. structure ------------------------------------------------------
    out1 = os.path.join(work, "out1")
    p = assemble(good, out1)
    check("assemble of a good set is rc 0", p.returncode == 0, detail=p.stdout + p.stderr)
    rel = read(out1, "deb/dists/trixie/Release") if p.returncode == 0 else ""
    check("Release has Origin, Label, Acquire-By-Hash, Architectures",
          all(x in rel for x in ("Origin: LibreSCRS\n", "Label: LibreSCRS\n", "Acquire-By-Hash: yes\n",
                                 "Architectures: amd64 all\n")), detail=rel)
    rfc = lambda t: email.utils.formatdate(t, usegmt=True)
    check("Valid-Until is now + 30 days (RFC 2822 UTC)", f"\nValid-Until: {rfc(NOW + 30 * 86400)}\n" in rel, detail=rel)
    check("Date is now", f"\nDate: {rfc(NOW)}\n" in rel, detail=rel)
    byh = os.path.join(out1, "deb/dists/trixie/main/binary-amd64/by-hash/SHA256")
    names = os.listdir(byh) if os.path.isdir(byh) else []
    import hashlib
    shas = [hashlib.sha256(open(os.path.join(out1, "deb/dists/trixie/main/binary-amd64", n), "rb").read()).hexdigest()
            for n in ("Packages", "Packages.xz")] if names else []
    check("by-hash exists for Packages and Packages.xz", len(shas) == 2 and all(s in names for s in shas))
    check("Release lists Packages and Packages.xz by hash",
          all(f" {s} " in rel for s in shas) and "main/binary-amd64/Packages.xz" in rel)
    check("trixie Packages holds librescrs-archive-keyring",
          "Package: librescrs-archive-keyring" in read(out1, "deb/dists/trixie/main/binary-amd64/Packages"))
    check("pool names come from the fields (~ becomes .)",
          os.path.isfile(os.path.join(out1, "deb/pool/trixie/liblibrescrs5_5.0.0-1.deb13_amd64.deb"))
          and os.path.isfile(os.path.join(out1, "deb/pool/resolute/liblibrescrs5_5.0.0-1.ubuntu26.04_amd64.deb")))
    check("rpm tree has repomd.xml and repomd.xml.key for opensusetw",
          os.path.isfile(os.path.join(out1, "rpm/opensusetw/repodata/repomd.xml"))
          and filecmp.cmp(os.path.join(out1, "rpm/opensusetw/repodata/repomd.xml.key"), os.path.join(HERE, "../keys/rehearsal.asc"), False))
    check("KEY.asc is the key set's certificate",
          filecmp.cmp(os.path.join(out1, "KEY.asc"), os.path.join(HERE, "../keys/rehearsal.asc"), False))
    check("KEYS and index.html are written",
          read(out1, "KEYS") == "fixture KEYS\n" and "LibreSCRS" in read(out1, "index.html"))
    alias = ["librescrs-archive-keyring-trixie.deb", "librescrs-archive-keyring-resolute.deb",
             "librescrs-release-fedora.noarch.rpm", "librescrs-release-opensusetw.noarch.rpm"]
    check("the keyring packages are there under their stable names",
          all(os.path.isfile(os.path.join(out1, a)) for a in alias))
    check("the Fedora alias is the fedora43 build",
          filecmp.cmp(os.path.join(out1, "librescrs-release-fedora.noarch.rpm"),
                      os.path.join(fx, "rpms", "librescrs-release-1.0.0-1.fedora43.noarch.fedora43.rpm"), False))
    check("the keyring rpm is in the repodata too",
          "librescrs-release" in sh("bash", "-c", f"zstdcat {out1}/rpm/fedora43/repodata/*primary.xml.zst").stdout)

    # ---- 2. red: an ubuntu build in the trixie set -------------------------
    bad = layout("in-bad", swap_ubuntu_into_trixie=True)
    p = assemble(bad, os.path.join(work, "out-bad"))
    check("a ~ubuntu26.04 package under debian13 is rc 1", p.returncode == 1 and "does not end in ~deb13" in p.stdout,
          red=True, detail=f"rc {p.returncode} {p.stdout}{p.stderr}")

    # ---- 3. cannot judge ---------------------------------------------------
    p = assemble(layout("in-nokeys", keys=False), os.path.join(work, "out-nokeys"))
    check("no KEYS is rc 2", p.returncode == 2 and "KEYS" in p.stderr, red=True, detail=f"rc {p.returncode} {p.stderr}")
    prev = os.path.join(work, "prev")
    os.makedirs(prev)
    open(os.path.join(prev, "x"), "w").close()
    p = assemble(good, os.path.join(work, "out-prev"), prev=prev)
    check("a --prev that is no fetch-prev mirror is rc 2", p.returncode == 2 and "--prev" in p.stderr, red=True,
          detail=f"rc {p.returncode} {p.stderr}")
    os.makedirs(os.path.join(work, "prev-empty"))
    p = assemble(good, os.path.join(work, "out-pe"), prev=os.path.join(work, "prev-empty"))
    check("an empty --prev is no merge", p.returncode == 0, detail=p.stderr)

    # ---- 4. determinism ----------------------------------------------------
    out2 = os.path.join(work, "out2")
    p = assemble(good, out2, now=NOW + 7 * 86400)
    check("the second assemble is rc 0", p.returncode == 0, detail=p.stderr)
    diffs = []
    for dp, _, fs in os.walk(out1):
        for n in fs:
            a = os.path.join(dp, n)
            b = os.path.join(out2, os.path.relpath(a, out1))
            if not os.path.isfile(b) or not filecmp.cmp(a, b, False):
                diffs.append(os.path.relpath(a, out1))
    extra = [os.path.relpath(os.path.join(dp, n), out2) for dp, _, fs in os.walk(out2) for n in fs
             if not os.path.exists(os.path.join(out1, os.path.relpath(os.path.join(dp, n), out2)))]
    check("only the Release files differ between assembles 7 days apart",
          sorted(diffs) == ["deb/dists/resolute/Release", "deb/dists/trixie/Release"] and not extra,
          detail=f"differ: {diffs} extra: {extra}")
    a_, b_ = read(out1, "deb/dists/trixie/Release").splitlines(), read(out2, "deb/dists/trixie/Release").splitlines()
    check("...and in them only Date and Valid-Until",
          [x for x, y in zip(a_, b_) if x != y and not x.startswith(("Date:", "Valid-Until:"))] == [] and len(a_) == len(b_))
    # ---- 5. --prev: the previous generation is carried one more generation --
    # generation 2 lacks a deb and an rpm that generation 1 (out1) had, so its
    # indexes differ and the old ones are exactly what a cached index names
    gen2 = layout("in-gen2")
    os.unlink(os.path.join(gen2, "LibreMiddleware/5.0.0/liblibrescrs5_5.0.0-1.deb13_amd64.debian13.deb"))
    os.unlink(os.path.join(gen2, "LibreMiddleware/5.0.0/libls-5.0.0-1.fedora43.noarch.fedora43.rpm"))
    outg = os.path.join(work, "out-gen2")
    p = assemble(gen2, outg, prev=out1)
    check("assemble with a previous generation is rc 0", p.returncode == 0 and "carried" in p.stdout,
          detail=f"{p.stdout}{p.stderr}")
    outn = os.path.join(work, "out-gen2-alone")
    p = assemble(gen2, outn)
    check("assemble of generation 2 alone is rc 0", p.returncode == 0, detail=p.stderr)

    def old_files(sub):
        """the files of generation 1 under `sub` that are not in the lone generation 2"""
        found = []
        for dp, _, fs in os.walk(os.path.join(out1, sub)):
            for n in fs:
                rel_ = os.path.relpath(os.path.join(dp, n), out1)
                if not os.path.exists(os.path.join(outn, rel_)):
                    found.append(rel_)
        return found

    old_byhash = [r for r in old_files("deb/dists") if "/by-hash/" in r]
    old_repodata = [r for r in old_files("rpm") if "/repodata/" in r and "repomd" not in r]
    old_pool = [r for r in old_files("deb/pool") + old_files("rpm") if r.endswith((".deb", ".rpm"))]
    check("the fixture has old by-hash, repodata and pool files to carry",
          bool(old_byhash) and bool(old_repodata) and len(old_pool) >= 2,
          detail=f"{old_byhash} {old_repodata} {old_pool}")
    check("the old by-hash files are in the new tree",
          all(filecmp.cmp(os.path.join(out1, r), os.path.join(outg, r), False) for r in old_byhash)
          and any("trixie" in r for r in old_byhash), detail=str(old_byhash))
    check("the old *-primary.xml.zst is in the new tree",
          any(r.endswith("primary.xml.zst") for r in old_repodata)
          and all(filecmp.cmp(os.path.join(out1, r), os.path.join(outg, r), False) for r in old_repodata))
    check("the old pool deb and rpm are in the new tree",
          all(filecmp.cmp(os.path.join(out1, r), os.path.join(outg, r), False) for r in old_pool))
    check("the new by-hash files are still there",
          all(os.path.exists(os.path.join(outg, os.path.relpath(os.path.join(dp, n), outn)))
              for dp, _, fs in os.walk(os.path.join(outn, "deb/dists")) for n in fs))
    check("the current repomd.xml is the new generation's, not the old one's",
          filecmp.cmp(os.path.join(outg, "rpm/fedora43/repodata/repomd.xml"),
                      os.path.join(outn, "rpm/fedora43/repodata/repomd.xml"), False)
          and not filecmp.cmp(os.path.join(outg, "rpm/fedora43/repodata/repomd.xml"),
                              os.path.join(out1, "rpm/fedora43/repodata/repomd.xml"), False))
    # the repomd.xml of the new tree names only its own primary, the one in the lone tree
    check("the carried packages are not in the new indexes",
          "liblibrescrs5" not in read(outg, "deb/dists/trixie/main/binary-amd64/Packages")
          and read(outg, "deb/dists/trixie/main/binary-amd64/Packages") == read(outn, "deb/dists/trixie/main/binary-amd64/Packages")
          and read(outg, "deb/dists/trixie/Release") == read(outn, "deb/dists/trixie/Release")
          and "<name>libls</name>" not in sh("bash", "-c", f"zstdcat {outn}/rpm/fedora43/repodata/*primary.xml.zst").stdout
          and "<name>libls</name>" in sh("bash", "-c", f"zstdcat {out1}/rpm/fedora43/repodata/*primary.xml.zst").stdout)
    check("RED the lone generation 2 lacks every file --prev carries",
          bool(old_byhash) and not any(os.path.exists(os.path.join(outn, r)) for r in old_byhash + old_repodata + old_pool),
          red=True)
    os.makedirs(os.path.join(work, "prev-EMPTY"))
    open(os.path.join(work, "prev-EMPTY", "EMPTY"), "w").write("no published generation\n")
    p = assemble(gen2, os.path.join(work, "out-gen2-e"), prev=os.path.join(work, "prev-EMPTY"))
    check("a fetch-prev EMPTY mirror merges nothing", p.returncode == 0 and "carried" not in p.stdout, detail=p.stderr)
    # ---- 6. sign-index and verify-tree over the real tree -------------------
    def tool_(*argv):
        return sh(sys.executable, "-I", TOOL, *argv)

    p = tool_("verify-tree", "--tree", out1, "--keyset", "rehearsal", "--unsigned", "--now", str(NOW + 60))
    check("verify-tree --unsigned: the assembled tree's hash chain holds", p.returncode == 0, detail=p.stdout + p.stderr)
    signed = os.path.join(work, "signed")
    shutil.copytree(out1, signed)
    p = tool_("sign-index", "--tree", signed, "--keyset", "rehearsal")
    check("sign-index of the assembled tree is rc 0", p.returncode == 0, detail=p.stdout + p.stderr)
    p = tool_("verify-tree", "--tree", signed, "--keyset", "rehearsal", "--now", str(NOW + 60))
    check("verify-tree of the signed tree is rc 0, every rpm verified",
          p.returncode == 0 and p.stdout.count("verified  ") == sum(
              n.endswith(".rpm") for s in ("fedora43", "fedora44", "opensusetw") for n in os.listdir(os.path.join(signed, "rpm", s))),
          detail=p.stdout + p.stderr)
    unsigned_in = layout("in-unsigned")
    shutil.copyfile(os.path.join(fx, "unsigned", UNSIGNED), os.path.join(unsigned_in, "LibreMiddleware/5.0.0", UNSIGNED))
    out_u = os.path.join(work, "out-unsigned")
    p = assemble(unsigned_in, out_u)
    check("assemble of a set with an unsigned rpm is rc 0 (assemble judges no signature)", p.returncode == 0,
          detail=p.stdout + p.stderr)
    p = tool_("sign-index", "--tree", out_u, "--keyset", "rehearsal")
    q = tool_("verify-tree", "--tree", out_u, "--keyset", "rehearsal", "--now", str(NOW + 60))
    check("an unsigned rpm under a correctly signed index is rc 1",
          p.returncode == 0 and q.returncode == 1
          and "libls-5.0.0-1.fedora44.noarch.fedora44.rpm does not verify against the package certificate" in q.stdout,
          red=True, detail=f"sign rc {p.returncode}, verify rc {q.returncode}\n{q.stdout}{q.stderr}")
    if os.environ.get("PKG_REPO_DT_LIST"):  # show the assembled tree
        print(sh("bash", "-c", f"cd {out1} && find . | LC_ALL=C sort | head -60").stdout)
finally:
    shutil.rmtree(work, ignore_errors=True)
    if os.path.exists(work):
        sh("docker", "run", "--rm", "-v", f"{work}:/w", image("debian13"), "rm", "-rf", "/w")
        shutil.rmtree(work, ignore_errors=True)

print(f"selftest: {cases} cases, {reds} red-proved")
sys.exit(1 if fails else 0)
