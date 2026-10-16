#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Self-test for pkg-repo.py select, fetch-releases, fetch-prev, sign-index,
verify-tree and watch, and for the run blocks of actions/pkg-repo and
actions/pkg-sign where they decide alone (the published output, the key
refusals), with fakes
for gh, release-seal.sh and pkg-sign.sh (no Docker, no outside network). The
real check-release-assets.sh judges the asset sets. fetch-prev runs against a
local HTTP server that serves a "previous generation" signed here with the
rehearsal key's index subkey (and with foreign keys for the red cases), in
GNUPGHOMEs of their own. sign-index signs such a tree left unsigned, and the
tree it signs is judged by verify-tree and mirrored by fetch-prev; the rpm
signatures verify-tree asks pkg-sign.sh about are the fake's answer here (the
real ones are pkg-repo.dockertest.py's). Each action case is also run over a
copy of the action with its guard taken out, and must then fail: the
guard, not something beside it, is what the case sees."""
import atexit
import functools
import hashlib
import http.server
import json
import lzma
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "pkg-repo.py")
REPOS = ["LibreMiddleware", "LibreAgent", "LibreLinux", "LibreCelik", "LibreKDE", "packages"]
cases = red = 0
failed = False
root = tempfile.mkdtemp(dir=os.environ.get("TMPDIR", "/var/tmp"), prefix="pkg-repo-st.")
atexit.register(shutil.rmtree, root, True)

FAKE_GH = r"""#!/usr/bin/env bash
F="$FAKE_ROOT"
case "$1 $2" in
  "api repos/LibreSCRS/"*"/releases?per_page=100") r="${2#repos/LibreSCRS/}"; cat "$F/${r%%/*}/releases.json" ;;
  "api repos/LibreSCRS/"*"/contents/ci/release-assets.txt"*) r="${2#repos/LibreSCRS/}"; cat "$F/${r%%/*}/decl.txt" ;;
  "release download") tag="$3"; repo="${5#LibreSCRS/}"; d="$7"
      [ -d "$F/$repo/assets/$tag" ] && cp -r "$F/$repo/assets/$tag/." "$d/"; exit 0 ;;
  "run download") repo="${5#LibreSCRS/}"; d="${9}"
      [ -d "$F/$repo/rehearse" ] && cp -r "$F/$repo/rehearse/." "$d/"; exit 0 ;;
  *) echo "fake gh: $*" >&2; exit 9 ;;
esac
"""
FAKE_SEAL = r"""#!/usr/bin/env bash
echo "seal $*" >> "$FAKE_ROOT/calls.log"
[ "$1" = verify-release ] && [ "$3" != "LibreSCRS/${FAKE_SEAL_FAIL:-none}" ] && exit 0
exit 1
"""
FAKE_SIGN = r"""#!/usr/bin/env bash
echo "sign $*" >> "$FAKE_ROOT/calls.log"
if [ "$1" = --dir ]; then ls "$2" >> "$FAKE_ROOT/calls.log"; fi
exit "${FAKE_SIGN_RC:-0}"
"""


def script(name, body):
    p = os.path.join(root, name)
    with open(p, "w") as f:
        f.write(body)
    os.chmod(p, 0o755)
    return p


GH = script("gh", FAKE_GH)
SEAL = script("seal", FAKE_SEAL)
SIGN = script("sign", FAKE_SIGN)


def write(path, data=b""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())


def rel(*tags):
    return json.dumps([dict(tag_name=t, prerelease=False, draft=False) for t in tags])


def fixture(name, tags=("5.0.0",), files=("a.deb",), decl="*.deb  Debian package\n", rehearse=False):
    """A fake GitHub: every repository has the same assets under each tag."""
    f = os.path.join(root, "fx", name)
    for r in REPOS:
        t = tags if r != "packages" else ("1.0.0",)
        write(os.path.join(f, r, "releases.json"), rel(*t))
        write(os.path.join(f, r, "decl.txt"), decl)
        for tag in t:
            for n in files:
                write(os.path.join(f, r, "assets", tag, n), n)
        if rehearse:
            for n in files:
                write(os.path.join(f, r, "rehearse", n), n)
            sums = "".join(f"{hashlib.sha256(n.encode()).hexdigest()}  {n}\n" for n in files)
            write(os.path.join(f, r, "rehearse", "SHA256SUMS"), sums)
    return f


def run(argv, env=None, tool=TOOL, **kw):
    e = dict(os.environ, PKG_REPO_GH=GH, PKG_REPO_SEAL=SEAL, PKG_REPO_SIGN=SIGN)
    e.update(env or {})
    return subprocess.run([sys.executable, tool] + argv, capture_output=True, text=True, env=e, **kw)


def check(name, p, want, text=None, red_case=False, extra=None):
    global cases, red, failed
    cases += 1
    ok = p.returncode == want
    out = p.stdout + p.stderr
    if ok and text is not None and text not in out:
        ok = False
    if ok and extra is not None and not extra():
        ok = False
    if red_case and ok:
        red += 1
    if not ok:
        failed = True
        print(f"FAIL {name}: rc {p.returncode} (want {want}), text {text!r}\n{out}")
    else:
        print(f"ok   {name}")


def select(name, json_text, want_rc, want_out=None, keep=2, minimum="5.0.0", red_case=False):
    p_json = os.path.join(root, "rel-" + name.split(":")[0].replace(" ", "-") + ".json")
    write(p_json, json_text)
    p = run(["select", "--releases", p_json, "--keep", str(keep), "--min", minimum])
    check(name, p, want_rc, red_case=red_case,
          extra=lambda: "Traceback" not in p.stdout + p.stderr
          and (want_out is None or p.stdout.split() == want_out))


def calls(f):
    try:
        return open(os.path.join(f, "calls.log")).read()
    except OSError:
        return ""


# ---- select
select("1 select: newest first, prerelease and old skipped",
       json.dumps([dict(tag_name="5.0.0", prerelease=False, draft=False),
                   dict(tag_name="5.0.1", prerelease=False, draft=False),
                   dict(tag_name="4.2.3", prerelease=False, draft=False),
                   dict(tag_name="5.1.0-rc1", prerelease=True, draft=False),
                   dict(tag_name="5.2.0", prerelease=False, draft=True)]),
       0, ["5.0.1", "5.0.0"])
select("2 select: one tag is enough", rel("5.0.0"), 0, ["5.0.0"])
select("3 select: only 4.2.0 is red", rel("4.2.0"), 1, red_case=True)
select("4 select: packages keep 1 min 1.0.0", rel("1.0.0"), 0, ["1.0.0"], keep=1, minimum="1.0.0")
select("5 select: semver, not text, order", rel("5.9.0", "5.10.0", "5.2.0"), 0, ["5.10.0", "5.9.0"])
select("5b RED select: a release that is no JSON object is rc 2, not a traceback", "[1]", 2, red_case=True)
select("5c RED select: --keep 0 is rc 2, not a traceback", rel("5.0.0"), 2, keep=0, red_case=True)

# ---- fetch-releases, publish
f = fixture("ok")
out = os.path.join(root, "out-ok")
p = run(["fetch-releases", "--out", out, "--mode", "publish"], {"FAKE_ROOT": f})
check("6 publish: all six repositories verified", p, 0,
      extra=lambda: os.path.isfile(os.path.join(out, "LibreKDE", "5.0.0", "a.deb"))
      and os.path.isfile(os.path.join(out, "packages", "1.0.0", "a.deb"))
      and "seal verify-release" in calls(f)
      and f"LibreSCRS/LibreCelik refs/tags/5.0.0" in calls(f)
      and "sign " not in calls(f))

f = fixture("two", tags=("5.0.0", "5.0.1", "4.0.0"))
out = os.path.join(root, "out-two")
p = run(["fetch-releases", "--out", out, "--mode", "publish"], {"FAKE_ROOT": f})
check("7 publish: keep 2 downloads two tags, packages one", p, 0,
      extra=lambda: os.path.isdir(os.path.join(out, "LibreLinux", "5.0.1"))
      and os.path.isdir(os.path.join(out, "LibreLinux", "5.0.0"))
      and not os.path.exists(os.path.join(out, "LibreLinux", "4.0.0")))

f = fixture("empty", files=())
p = run(["fetch-releases", "--out", os.path.join(root, "out-empty"), "--mode", "publish"], {"FAKE_ROOT": f})
check("8 RED publish: empty download is rc 1, no asset", p, 1, "no asset", red_case=True)

f = fixture("extra", files=("a.deb", "extra.rpm"))
write(os.path.join(f, "LibreAgent", "decl.txt"), "*.deb  Debian package\n")
for r in REPOS:
    if r != "LibreAgent":
        write(os.path.join(f, r, "decl.txt"), "*.deb  d\n*.rpm  r\n")
p = run(["fetch-releases", "--out", os.path.join(root, "out-extra"), "--mode", "publish"], {"FAKE_ROOT": f})
check("9 RED publish: a file no glob covers is rc 1", p, 1, "extra.rpm", red_case=True)

f = fixture("extra2", files=("a.deb", "extra.deb"))
for r in REPOS:
    write(os.path.join(f, r, "decl.txt"), "a.deb  d\n")
p = run(["fetch-releases", "--out", os.path.join(root, "out-extra2"), "--mode", "publish"], {"FAKE_ROOT": f})
check("10 RED publish: extra.deb covered by no glob", p, 1, "matches no glob", red_case=True)

f = fixture("noglobfile")
for r in REPOS:
    write(os.path.join(f, r, "decl.txt"), "*.deb  d\n*.rpm  r\n")
p = run(["fetch-releases", "--out", os.path.join(root, "out-ng"), "--mode", "publish"], {"FAKE_ROOT": f})
check("11 RED publish: a glob with no file is rc 1", p, 1, "declared but nothing", red_case=True)

f = fixture("seal")
p = run(["fetch-releases", "--out", os.path.join(root, "out-seal"), "--mode", "publish"],
        {"FAKE_ROOT": f, "FAKE_SEAL_FAIL": "LibreLinux"})
check("12 RED publish: verify-release fails for one repo", p, 1, "provenance", red_case=True)

f = fixture("rpm", files=("a.deb", "b.fedora43.rpm"), decl="*.deb  d\n*.rpm  r\n")
p = run(["fetch-releases", "--out", os.path.join(root, "out-rpm"), "--mode", "publish"], {"FAKE_ROOT": f})
check("13 publish: rpms are verified against package-signing", p, 0,
      extra=lambda: "--keyset package-signing --verify-only" in calls(f))
p = run(["fetch-releases", "--out", os.path.join(root, "out-rpm1"), "--mode", "publish"],
        {"FAKE_ROOT": f, "FAKE_SIGN_RC": "1"})
check("14 RED publish: an rpm signature failure is rc 1", p, 1, red_case=True)
p = run(["fetch-releases", "--out", os.path.join(root, "out-rpm2"), "--mode", "publish"],
        {"FAKE_ROOT": f, "FAKE_SIGN_RC": "2"})
check("15 RED publish: sign cannot judge stays rc 2", p, 2, red_case=True)

for label, body in (("15b RED publish: a releases list holding no object is rc 2, not a traceback", "[1]"),
                    ("15c RED publish: a releases answer that is an object is rc 2, not a traceback",
                     '{"message": "Not Found"}')):
    f = fixture("badjson" + label.split()[0])
    write(os.path.join(f, "LibreAgent", "releases.json"), body)
    p = run(["fetch-releases", "--out", os.path.join(root, "out-" + label.split()[0]), "--mode", "publish"],
            {"FAKE_ROOT": f})
    check(label, p, 2, "cannot judge", red_case=True, extra=lambda: "Traceback" not in p.stdout + p.stderr)

f = fixture("notag", tags=("4.2.0",))
write(os.path.join(f, "packages", "releases.json"), rel("1.0.0"))
p = run(["fetch-releases", "--out", os.path.join(root, "out-nt"), "--mode", "publish"], {"FAKE_ROOT": f})
check("16 RED publish: no tag >= min is rc 1", p, 1, "no release tag", red_case=True)
none = os.path.join(root, "out-none")
f = fixture("none", tags=("4.2.0",))
write(os.path.join(f, "packages", "releases.json"), rel())
p = run(["fetch-releases", "--out", os.path.join(root, "out-none0"), "--mode", "publish"], {"FAKE_ROOT": f})
check("16b RED publish: nothing released, no --allow-none, is rc 1", p, 1, "no release tag", red_case=True)
p = run(["fetch-releases", "--out", none, "--mode", "publish", "--allow-none"], {"FAKE_ROOT": f})
check("16c publish --allow-none: nothing released is NONE, rc 0", p, 0, "nothing released yet",
      extra=lambda: os.listdir(none) == ["NONE"] and "LibreMiddleware >= 5.0.0" in open(os.path.join(none, "NONE")).read())
none2 = os.path.join(root, "out-none2")
f = fixture("none2", tags=("4.2.0",))
p = run(["fetch-releases", "--out", none2, "--mode", "publish", "--allow-none"], {"FAKE_ROOT": f})
check("16g publish --allow-none: packages 1.0.0 released, no code 5.0.0, is NONE, rc 0", p, 0,
      "nothing released yet", extra=lambda: os.listdir(none2) == ["NONE"])
f = fixture("notag2", tags=("4.2.0",))
write(os.path.join(f, "LibreMiddleware", "releases.json"), rel("5.0.0"))
write(os.path.join(f, "LibreMiddleware", "assets", "5.0.0", "a.deb"), "a.deb")
p = run(["fetch-releases", "--out", os.path.join(root, "out-nt2"), "--mode", "publish", "--allow-none"],
        {"FAKE_ROOT": f})
check("16d RED publish --allow-none: LibreMiddleware 5.0.0 released, the rest not, is rc 1", p, 1,
      "LibreAgent: no release tag", red_case=True,
      extra=lambda: not os.path.exists(os.path.join(root, "out-nt2", "NONE")))
f = fixture("ok2")
p = run(["fetch-releases", "--out", os.path.join(root, "out-ok2"), "--mode", "publish", "--allow-none"],
        {"FAKE_ROOT": f})
check("16e publish --allow-none: releases present are fetched as without it", p, 0,
      extra=lambda: os.path.isfile(os.path.join(root, "out-ok2", "LibreKDE", "5.0.0", "a.deb"))
      and not os.path.exists(os.path.join(root, "out-ok2", "NONE")))
p = run(["fetch-releases", "--out", os.path.join(root, "out-rn"), "--mode", "rehearse", "--allow-none"],
        {"FAKE_ROOT": f, "RUNS": ""})
check("16f RED rehearse --allow-none cannot judge", p, 2, "--allow-none is for --mode publish", red_case=True)

# ---- fetch-releases, rehearse
f = fixture("reh", files=("a.deb",), decl="*.deb  d\nSHA256SUMS  s\n", rehearse=True)
runs6 = " ".join(f"{r}={i + 100}" for i, r in enumerate(REPOS))
p = run(["fetch-releases", "--out", os.path.join(root, "out-reh"), "--mode", "rehearse"],
        {"FAKE_ROOT": f, "RUNS": runs6})
check("17 rehearse: six runs verified, cosign skipped", p, 0,
      "cosign skipped: a rehearsal signs with an ephemeral key (release-seal.sh)",
      extra=lambda: "seal" not in calls(f))

p = run(["fetch-releases", "--out", os.path.join(root, "out-reh5"), "--mode", "rehearse"],
        {"FAKE_ROOT": f, "RUNS": " ".join(runs6.split()[:5])})
check("18 RED rehearse: five runs, packages missing, rc 2", p, 2, "packages missing", red_case=True)

write(os.path.join(f, "LibreCelik", "rehearse", "a.deb"), "tampered")
p = run(["fetch-releases", "--out", os.path.join(root, "out-reh2"), "--mode", "rehearse"],
        {"FAKE_ROOT": f, "RUNS": runs6})
check("19 RED rehearse: SHA256SUMS mismatch is rc 1", p, 1, "SHA256SUMS", red_case=True)

f = fixture("reh-rpm", files=("a.deb", "b.fedora43.rpm", "SHA256SUMS"), decl="*.deb  d\n*.rpm  r\nSHA256SUMS  s\n", rehearse=True)
for r in REPOS:  # SHA256SUMS covers the other two files only
    base = os.path.join(f, r, "rehearse")
    write(os.path.join(base, "SHA256SUMS"), "".join(
        f"{hashlib.sha256(n.encode()).hexdigest()}  {n}\n" for n in ("a.deb", "b.fedora43.rpm")))
p = run(["fetch-releases", "--out", os.path.join(root, "out-reh3"), "--mode", "rehearse"],
        {"FAKE_ROOT": f, "RUNS": runs6})
check("20 rehearse: rpms are verified against the rehearsal key set", p, 0,
      extra=lambda: "--keyset rehearsal --verify-only" in calls(f))

homes = []
try:
    # ---- fetch-prev
    KEYS_DIR = os.path.join(HERE, "..", "keys")
    ENV = dict(l.strip().split("=", 1) for l in open(os.path.join(KEYS_DIR, "rehearsal.env")) if "=" in l)
    CERT = open(os.path.join(KEYS_DIR, "rehearsal.asc"), "rb").read()


    def gpg_home():
        h = tempfile.mkdtemp(dir="/var/tmp", prefix="lg.")
        homes.append(h)
        os.chmod(h, 0o700)
        return h


    def gpg(home, *argv, data=None):
        return subprocess.run(["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase", ""] + list(argv),
                              capture_output=True, env=dict(os.environ, GNUPGHOME=home), input=data)


    def secret_fprs(home):
        p = gpg(home, "--list-secret-keys", "--with-colons")
        return {l.split(":")[9] for l in p.stdout.decode().splitlines() if l.startswith("fpr:")}


    HOME_A, HOME_B = gpg_home(), gpg_home()
    if gpg(HOME_A, "--import", os.path.join(KEYS_DIR, "rehearsal.sec.asc")).returncode:
        print("FATAL: cannot import the rehearsal key -- cannot measure")
        sys.exit(2)
    gpg(HOME_B, "--quick-generate-key", "foreign key B <b@invalid>", "ed25519", "sign", "never")
    # only the fixture keys are in the keyrings that sign
    if secret_fprs(HOME_A) != set(ENV.values()) or len(secret_fprs(HOME_B)) < 1 or secret_fprs(HOME_B) & set(ENV.values()):
        print("FATAL: the fixture keyrings hold other keys than the fixture's -- cannot measure")
        sys.exit(2)
    KEY_B = sorted(secret_fprs(HOME_B))[0]
    IDX = (HOME_A, ENV["S_IDX_FPR"])
    FOREIGN = (HOME_B, KEY_B)
    OTHER_SUBKEY = (HOME_A, ENV["S_RPM_FPR"])  # ours, but not the index signer

    SLUGS = ("fedora43", "fedora44", "opensusetw")
    CODENAMES = ("trixie", "resolute")


    def sign_file(path, how, key):
        home, fpr = key
        flags = {"clear": ["--clearsign", "--output", path + ".sig"], "detach": ["--detach-sign", "--armor", "--output", path + ".sig"]}[how]
        p = gpg(home, "--local-user", fpr + "!", *flags, path)
        if p.returncode:
            print(f"FATAL: cannot sign the fixture -- cannot measure\n{p.stderr.decode()}")
            sys.exit(2)
        return path + ".sig"


    def sha(b):
        return hashlib.sha256(b).hexdigest()


    NOW = int(time.time())
    RFC = lambda t: time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime(t))
    VALID_UNTIL = NOW + 30 * 86400
    # what assemble writes next to the indexes; fetch-prev mirrors all of it
    # but index.html
    EXTRAS = {"KEYS": "fixture KEYS\n", "index.html": "<!doctype html>\n",
              "librescrs-archive-keyring-trixie.deb": "deb/pool/trixie/other_1_all.deb",
              "librescrs-archive-keyring-resolute.deb": "deb/pool/resolute/other_1_all.deb",
              "librescrs-release-fedora.noarch.rpm": "rpm/fedora43/{d}libls-5.0.0-1.noarch.rpm",
              "librescrs-release-opensusetw.noarch.rpm": "rpm/opensusetw/{d}libls-5.0.0-1.noarch.rpm"}


    def build_site(name, sign=None, signed=True, extras=True, valid_until=VALID_UNTIL, rpm_dir="", more_slugs=()):
        """A published tree as assemble + the signer would leave it; `sign` maps
        "<file>" -> key for the files a red case signs with another key.
        signed=False leaves it as assemble does (no InRelease, Release.gpg or
        repomd.xml.asc); extras (the default, as assemble writes them) adds
        the stable aliases, KEYS and index.html;
        rpm_dir puts every rpm in that subdirectory of its slug; more_slugs
        are rpm slugs beyond the ones the code builds, indexed and signed the same."""
        sign = sign or {}
        site = os.path.join(root, "site-" + name)
        w = lambda rel_, data: write(os.path.join(site, rel_), data)
        for c in CODENAMES:
            deb = f"pool/{c}/liblibrescrs5_5.0.0-1_amd64.deb"
            blob = f"deb {c} ".encode() * 50
            w("deb/" + deb, blob)
            pk = (f"Package: liblibrescrs5\nFilename: {deb}\nSize: {len(blob)}\nSHA256: {sha(blob)}\n\n"
                  f"Package: other\nFilename: pool/{c}/other_1_all.deb\nSize: 3\nSHA256: {sha(b'abc')}\n").encode()
            w(f"deb/pool/{c}/other_1_all.deb", b"abc")
            base = f"deb/dists/{c}"
            ents = []
            for n, data in (("Packages", pk), ("Packages.xz", lzma.compress(pk))):
                w(f"{base}/main/binary-amd64/{n}", data)
                w(f"{base}/main/binary-amd64/by-hash/SHA256/{sha(data)}", data)
                ents.append(f" {sha(data)} {len(data):>10} main/binary-amd64/{n}")
            vu = f"Valid-Until: {RFC(valid_until)}\n" if valid_until else ""
            rel_text = (f"Origin: LibreSCRS\nSuite: {c}\nCodename: {c}\nDate: {RFC(NOW)}\n{vu}"
                        "Acquire-By-Hash: yes\nSHA256:\n" + "\n".join(ents) + "\n")
            w(f"{base}/Release", rel_text)
            rp = os.path.join(site, base, "Release")
            if not signed:
                continue
            shutil.copyfile(sign_file(rp, "clear", sign.get(f"InRelease-{c}", IDX)), os.path.join(site, base, "InRelease"))
            shutil.copyfile(sign_file(rp, "detach", sign.get(f"Release.gpg-{c}", IDX)), os.path.join(site, base, "Release.gpg"))
            os.unlink(rp + ".sig")
        for s in SLUGS + tuple(more_slugs):
            rpm = f"rpm {s}".encode() * 40
            w(f"rpm/{s}/{rpm_dir}libls-5.0.0-1.noarch.rpm", rpm)
            prim = (f'<?xml version="1.0"?><metadata xmlns="http://linux.duke.edu/metadata/common" packages="1">'
                    f'<package type="rpm"><name>libls</name><checksum type="sha256" pkgid="YES">{sha(rpm)}</checksum>'
                    f'<location href="{rpm_dir}libls-5.0.0-1.noarch.rpm"/></package></metadata>').encode()
            z = subprocess.run(["zstd", "-q", "-c"], input=prim, capture_output=True).stdout
            w(f"rpm/{s}/repodata/{sha(z)}-primary.xml.zst", z)
            other = b"<filelists/>"
            w(f"rpm/{s}/repodata/{sha(other)}-other.xml", other)
            md = (f'<?xml version="1.0"?><repomd xmlns="http://linux.duke.edu/metadata/repo"><revision>1</revision>'
                  f'<data type="primary"><checksum type="sha256">{sha(z)}</checksum><location href="repodata/{sha(z)}-primary.xml.zst"/>'
                  f'<size>{len(z)}</size></data><data type="other"><checksum type="sha256">{sha(other)}</checksum>'
                  f'<location href="repodata/{sha(other)}-other.xml"/><size>{len(other)}</size></data></repomd>')
            w(f"rpm/{s}/repodata/repomd.xml", md)
            mp = os.path.join(site, f"rpm/{s}/repodata/repomd.xml")
            if signed:
                shutil.move(sign_file(mp, "detach", sign.get(f"repomd-{s}", IDX)), mp + ".asc")
            w(f"rpm/{s}/repodata/repomd.xml.key", CERT)
        w("KEY.asc", CERT)
        if extras:
            for n, v in EXTRAS.items():
                src = os.path.join(site, v.format(d=rpm_dir))
                w(n, open(src, "rb").read() if os.path.isfile(src) else v)
        return site


    class Handler(http.server.SimpleHTTPRequestHandler):
        status = {}   # path -> HTTP status to answer instead of the file

        def do_GET(self):
            code = self.status.get(self.path)
            if code:
                self.send_error(code)
                return
            super().do_GET()

        def log_message(self, *a):
            pass


    def serve(site, status=None):
        h = type("H", (Handler,), {"status": status or {}})
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(h, directory=site))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        return srv, f"http://127.0.0.1:{srv.server_address[1]}"


    def tree(d):
        return {os.path.relpath(os.path.join(dp, n), d): open(os.path.join(dp, n), "rb").read()
                for dp, _, fs in os.walk(d) for n in fs}


    def fetch_prev(name, site, want=0, text=None, red_case=False, status=None, expect=None, out=None, env=None,
                   tool=TOOL):
        srv, url = serve(site, status)
        out = out or os.path.join(root, "prev-" + name.split(" ")[0])
        try:
            p = run(["fetch-prev", "--url", url, "--keyset", "rehearsal", "--out", out], env, tool=tool)
        finally:
            srv.shutdown()
            srv.server_close()

        def extra():
            if "Traceback" in p.stderr + p.stdout:  # a refusal is said, never crashed
                return False
            if want == 1 and "::error::" not in p.stdout:
                return False
            if want != 0:  # a refusal keeps nothing, not even a partial mirror
                return not os.path.exists(out) and not os.path.exists(out + ".partial")
            return expect(out) if expect else True
        check(name, p, want, text, red_case, extra)
        return p


    # pkg-sign.sh as actions/pkg-sign reaches it ($GITHUB_ACTION_PATH/../../scripts):
    # a fake that records its arguments, so a run that gets past the guard shows.
    FAKE_ACTION_ROOT = os.path.join(root, "fake-ci")
    os.makedirs(os.path.join(FAKE_ACTION_ROOT, "scripts"))
    os.makedirs(os.path.join(FAKE_ACTION_ROOT, "actions", "pkg-sign"))
    script(os.path.join("fake-ci", "scripts", "pkg-sign.sh"), '#!/usr/bin/env bash\necho "$*" >> "$FAKE_SIGN_LOG"\n')

    def action_block(action):
        import yaml
        with open(os.path.join(HERE, "..", "actions", action, "action.yml"), encoding="utf-8") as f:
            return yaml.safe_load(f)["runs"]["steps"][0]["run"]

    def run_block(block, action, inputs, tmp):
        """A run block as the runner would run it, in tmp; the env names every input empty."""
        os.makedirs(tmp)
        out_file = os.path.join(tmp, "github-output")
        open(out_file, "w").close()
        e = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "RUNS")}
        if action == "pkg-repo":
            e.update({k: "" for k in ("STEP", "MODE", "KEYSET", "TREE", "RELEASES", "PREV", "KEY", "INSTALL_DIR",
                                      "PROBE_SLUGS", "PROBE_STEPS", "LIVE_URL", "SOURCES", "REMOTE_BASE",
                                      "SSH_KEY", "KNOWN_HOSTS")})
            e.update(CI_ROOT=os.path.join(HERE, ".."))
        else:
            e.update({k: "" for k in ("MODE", "PKGS", "KEY")})
            e.update(GITHUB_ACTION_PATH=os.path.join(FAKE_ACTION_ROOT, "actions", action),
                     FAKE_SIGN_LOG=os.path.join(tmp, "pkg-sign.log"))
        e.update(RUNNER_TEMP=tmp, GITHUB_OUTPUT=out_file)
        e.update({k: v(tmp) if callable(v) else v for k, v in inputs.items()})
        return subprocess.run(["bash", "-c", block], capture_output=True, text=True, env=e, cwd=tmp)

    def action_step(name, inputs, want, text=None, red_case=False, expect=None, action="pkg-repo", perturb=None,
                    unreached=None):
        """The run block of actions/<action>. unreached: text that must not
        be in the output -- what the step would print had it got past the
        refusal, so the rc is the refusal's own. With perturb=(old, new), the
        same case over a copy of the block with the guard `old` replaced by
        `new` must fail -- the proof that the guard is what the case sees.
        An input given as a function is called with the case's directory."""
        block = action_block(action)
        tag = name.split(" ")[0]
        tmp = os.path.join(root, f"action-{tag}")
        p = run_block(block, action, inputs, tmp)

        def holds(q, d):
            return (not expect or expect(d)) and (unreached is None or unreached not in q.stdout + q.stderr)
        check(name, p, want, text, red_case, lambda: holds(p, tmp))
        if perturb:
            global cases, failed
            cases += 1
            old, new = perturb
            if block.count(old) != 1:
                failed = True
                print(f"FAIL {name} (guard out): the guard occurs {block.count(old)} times in actions/{action}")
                return p
            tmp_p = os.path.join(root, f"action-{tag}-noguard")
            q = run_block(block.replace(old, new), action, inputs, tmp_p)
            out = q.stdout + q.stderr
            still = q.returncode == want and (text is None or text in out) and holds(q, tmp_p)
            if still:
                failed = True
                print(f"FAIL {name} (guard out): the case passes without its guard -- it does not see it\n{out}")
            else:
                print(f"ok   {name} (guard out: rc {q.returncode}, the case fails)")
        return p


    def flip(path, off=0):
        with open(path, "r+b") as f:
            f.seek(off)
            b = f.read(1)
            f.seek(off)
            f.write(bytes([b[0] ^ 1]))


    def site_as_mirrored(site):
        return {k: v for k, v in tree(site).items() if k != "index.html"}

    good = build_site("good")
    fetch_prev("21 fetch-prev: the whole previous tree is mirrored, the stable aliases and KEYS included", good,
               expect=lambda out: tree(out) == site_as_mirrored(good)
               and all(n in tree(out) for n in EXTRAS if n != "index.html")
               and os.stat(os.path.join(out, "KEY.asc")).st_mtime == 0)

    bad = build_site("keyb", {"InRelease-trixie": FOREIGN})
    fetch_prev("22 RED fetch-prev: InRelease signed by key B is rc 1", bad, 1, "signature", True)
    bad = build_site("subkey", {"InRelease-resolute": OTHER_SUBKEY})
    fetch_prev("23 RED fetch-prev: signed by our other subkey, not S_IDX, is rc 1", bad, 1, "not by the index signer", True)
    bad = build_site("relgpg", {"Release.gpg-trixie": FOREIGN})
    fetch_prev("24 RED fetch-prev: Release.gpg by key B is rc 1", bad, 1, "Release.gpg", True)
    bad = build_site("repomd", {"repomd-opensusetw": FOREIGN})
    fetch_prev("25 RED fetch-prev: repomd.xml.asc by key B is rc 1", bad, 1, "repomd.xml.asc", True)

    for label, rel_, text in (
            ("26 RED fetch-prev: a changed byte in a by-hash file is rc 1",
             "deb/dists/trixie/main/binary-amd64/by-hash/SHA256/{h}", "by-hash"),
            ("27 RED fetch-prev: a changed byte in a pool deb is rc 1", "deb/pool/resolute/liblibrescrs5_5.0.0-1_amd64.deb", "pool"),
            ("28 RED fetch-prev: a changed byte in an rpm is rc 1", "rpm/fedora44/libls-5.0.0-1.noarch.rpm", "libls"),
            ("29 RED fetch-prev: a changed byte in a repodata file nothing parses is rc 1", "rpm/fedora43/repodata/{o}-other.xml", "other.xml"),
            ("29b RED fetch-prev: a changed byte in the primary is rc 1", "rpm/fedora43/repodata/{z}-primary.xml.zst", "primary"),
            ("30 RED fetch-prev: a changed byte in KEY.asc is rc 1", "KEY.asc", "KEY.asc")):
        t = build_site("tamper")
        pk = open(os.path.join(t, "deb/dists/trixie/main/binary-amd64/Packages"), "rb").read()
        h = sha(pk)
        z = [n for n in os.listdir(os.path.join(t, "rpm/fedora43/repodata")) if n.endswith("primary.xml.zst")][0].split("-")[0]
        o = [n for n in os.listdir(os.path.join(t, "rpm/fedora43/repodata")) if n.endswith("other.xml")][0].split("-")[0]
        flip(os.path.join(t, rel_.format(h=h, z=z, o=o)), 12 if "primary" in rel_ else 0)
        fetch_prev(label, t, 1, text, True)
        shutil.rmtree(t)

    # the stable aliases: what install/*.txt downloads first, so the probe's
    # upgrade step can run them against the mirror
    t = build_site("aliasswap")
    shutil.copyfile(os.path.join(t, "deb/pool/resolute/liblibrescrs5_5.0.0-1_amd64.deb"),
                    os.path.join(t, "librescrs-archive-keyring-trixie.deb"))
    fetch_prev("30b RED fetch-prev: a stable alias the trixie index does not name is rc 1", t, 1,
               "librescrs-archive-keyring-trixie.deb: not a package the trixie index names", True)
    t = build_site("aliasrpm")
    write(os.path.join(t, "librescrs-release-opensusetw.noarch.rpm"), "another rpm")
    fetch_prev("30c RED fetch-prev: a release package alias no rpm primary names is rc 1", t, 1,
               "librescrs-release-opensusetw.noarch.rpm: not a package any rpm index of the previous generation names", True)

    # A previous generation built when a slug this code no longer lists was
    # the fedora alias's source: index.html links that slug, its signed index
    # names the alias, and only the alias is kept.
    def retired_site(name, alias_bytes=None):
        t = build_site(name, more_slugs=("fedora42",))
        src = os.path.join(t, "rpm/fedora42/libls-5.0.0-1.noarch.rpm")
        write(os.path.join(t, "librescrs-release-fedora.noarch.rpm"),
              alias_bytes if alias_bytes is not None else open(src, "rb").read())
        write(os.path.join(t, "index.html"), "".join(
            f'<li><a href="rpm/{s}/repodata/repomd.xml">rpm {s}</a></li>\n' for s in SLUGS + ("fedora42",)))
        return t
    t = retired_site("aliasretired")
    fetch_prev("30f fetch-prev: the fedora alias built for a slug this code no longer lists is green", t,
               expect=lambda out: open(os.path.join(out, "librescrs-release-fedora.noarch.rpm"), "rb").read()
               == open(os.path.join(t, "rpm/fedora42/libls-5.0.0-1.noarch.rpm"), "rb").read()
               and not os.path.exists(os.path.join(out, "rpm/fedora42")))
    t = retired_site("aliasretiredbad", b"not the fedora42 build")
    fetch_prev("30g RED fetch-prev: that alias with bytes no index names is rc 1", t, 1,
               "librescrs-release-fedora.noarch.rpm: not a package any rpm index of the previous generation names", True)
    t = build_site("aliasgone")
    os.unlink(os.path.join(t, "librescrs-release-fedora.noarch.rpm"))
    fetch_prev("30d RED fetch-prev: a published tree without a stable alias is rc 1", t, 1,
               "librescrs-release-fedora.noarch.rpm: named by a signed index (or required) but HTTP 404", True)
    t = build_site("keysgone")
    os.unlink(os.path.join(t, "KEYS"))
    fetch_prev("30e RED fetch-prev: a published tree without KEYS is rc 1", t, 1, "KEYS: named", True)

    def resign(site, c, release_text, inrelease_text=None, release_gpg=True):
        """Replace Release.gpg (over release_text, written as Release) and InRelease (over inrelease_text)
        of a codename, both signed by the index signer, so only the content differs."""
        base = os.path.join(site, "deb/dists", c)
        for name, text, how in (("Release", release_text, "detach"), ("InRelease", inrelease_text, "clear")):
            if text is None:
                continue
            src = os.path.join(root, "resign-src")
            write(src, text)
            shutil.move(sign_file(src, how, IDX), os.path.join(base, "Release.gpg" if name == "Release" else "InRelease"))
            if name == "Release":
                write(os.path.join(base, "Release"), text)


    t = build_site("relmismatch")
    rt = open(os.path.join(t, "deb/dists/trixie/Release")).read()
    resign(t, "trixie", "".join(l + "\n" for l in rt.splitlines() if not l.endswith("Packages.xz")))
    fetch_prev("31a RED fetch-prev: a signed Release naming another set than InRelease is rc 1", t, 1,
               "does not name what InRelease names", True)

    t = build_site("nocodename")
    rt = open(os.path.join(t, "deb/dists/trixie/Release")).read()
    resign(t, "trixie", rt, "".join(l + "\n" for l in rt.splitlines() if not l.startswith("Codename:")))
    fetch_prev("31b RED fetch-prev: an InRelease without a Codename is rc 1", t, 1, "Codename", True)

    t = build_site("othercodename")
    rt = open(os.path.join(t, "deb/dists/trixie/Release")).read()
    resign(t, "trixie", rt, rt.replace("Codename: trixie", "Codename: resolute"))
    fetch_prev("31c RED fetch-prev: an InRelease of another codename is rc 1", t, 1, "Codename", True)

    t = build_site("garbage")
    write(os.path.join(t, "deb/dists/trixie/InRelease"), "not a signed file\n")
    fetch_prev("31 RED fetch-prev: an InRelease that is not signed is rc 1", t, 1, "signature", True)

    t = build_site("noresolute")
    os.unlink(os.path.join(t, "deb/dists/resolute/InRelease"))
    fetch_prev("32 RED fetch-prev: resolute missing while trixie is published is rc 1", t, 1, "resolute/InRelease", True)

    t = build_site("namedgone")
    os.unlink(os.path.join(t, "deb/pool/trixie/other_1_all.deb"))
    fetch_prev("33 RED fetch-prev: a pool file the signed index names but the site lacks is rc 1", t, 1, "other_1_all", True)

    t = build_site("norepomdasc")
    os.unlink(os.path.join(t, "rpm/fedora43/repodata/repomd.xml.asc"))
    fetch_prev("34 RED fetch-prev: repomd.xml without its signature is rc 1", t, 1, "repomd.xml.asc", True)

    # no published generation: 404 on the first InRelease
    empty = os.path.join(root, "site-empty")
    os.makedirs(empty)
    fetch_prev("35 fetch-prev: HTTP 404 for trixie InRelease is EMPTY with a reason, rc 0", empty, 0,
               expect=lambda out: os.listdir(out) == ["EMPTY"] and "404" in open(os.path.join(out, "EMPTY")).read())

    # Before the first publish the package key need not exist: a ci without
    # the key set judges an empty site all the same, and only a published one
    # needs the key.
    nokeys = os.path.join(root, "ci-nokeys")
    os.makedirs(os.path.join(nokeys, "keys"))
    os.makedirs(os.path.join(nokeys, "scripts"))
    shutil.copyfile(TOOL, os.path.join(nokeys, "scripts", "pkg-repo.py"))
    fetch_prev("35b fetch-prev: HTTP 404 is EMPTY, rc 0, without the key set's files", empty, 0,
               tool=os.path.join(nokeys, "scripts", "pkg-repo.py"),
               expect=lambda out: os.listdir(out) == ["EMPTY"])
    fetch_prev("35c RED fetch-prev: a published generation without the key set's files is rc 2", good, 2,
               "no certificate or fingerprints for key set 'rehearsal'", True,
               tool=os.path.join(nokeys, "scripts", "pkg-repo.py"))

    fetch_prev("36 RED fetch-prev: HTTP 503 for trixie InRelease is rc 2, not EMPTY", good, 2, "503", True,
               {"/deb/dists/trixie/InRelease": 503})
    fetch_prev("37 RED fetch-prev: HTTP 503 for a pool file is rc 2", good, 2, "503", True,
               {"/deb/pool/trixie/other_1_all.deb": 503})
    fetch_prev("38 RED fetch-prev: HTTP 403 is rc 2", good, 2, "403", True, {"/KEY.asc": 403})

    # actions/pkg-repo: fetch-prev is a publish's step. The live site is under
    # package-signing, so a rehearsal judging it with its own key would be red
    # from the first publish on; the action refuses before reaching the site.
    # The site is one the rehearsal key could mirror, so only the refusal
    # keeps prev/ from being written.
    srv, url = serve(good)
    try:
        action_step("38c RED action fetch-prev: mode=rehearse is refused, rc 2, nothing written",
                    {"STEP": "fetch-prev", "MODE": "rehearse", "TREE": "prev", "LIVE_URL": url}, 2,
                    "::error::fetch-prev mirrors the published generation", True,
                    lambda d: not os.path.exists(os.path.join(d, "prev")))
    finally:
        srv.shutdown()
        srv.server_close()
    srv, url = serve(empty)
    try:
        action_step("38d action fetch-prev: mode=publish (keyset given, a fake site) still mirrors: EMPTY, rc 0",
                    {"STEP": "fetch-prev", "MODE": "publish", "KEYSET": "rehearsal", "TREE": "prev",
                     "LIVE_URL": url}, 0, "no published generation",
                    expect=lambda d: os.listdir(os.path.join(d, "prev")) == ["EMPTY"])
    finally:
        srv.shutdown()
        srv.server_close()

    bindir = os.path.join(root, "bin-nozstd")
    os.makedirs(bindir)
    for tool_ in ("gpg", "gpgv"):
        os.symlink(shutil.which(tool_), os.path.join(bindir, tool_))
    fetch_prev("38b RED fetch-prev: no zstd on PATH is rc 2, not a traceback", good, 2, "zstd", True,
               env={"PATH": bindir})

    srv, url = serve(good)
    srv.shutdown()
    srv.server_close()
    p = run(["fetch-prev", "--url", url, "--keyset", "rehearsal", "--out", os.path.join(root, "prev-down")])
    check("39 RED fetch-prev: a refused connection is rc 2", p, 2, "cannot judge", True,
          lambda: not os.path.exists(os.path.join(root, "prev-down")))

    busy = os.path.join(root, "prev-busy")
    write(os.path.join(busy, "x"), "x")
    p = run(["fetch-prev", "--url", url, "--keyset", "rehearsal", "--out", busy])
    check("40 RED fetch-prev: a non-empty --out is rc 2", p, 2, "not empty", True)

    # ---- sign-index and verify-tree
    def sign_index(tree_, keyset="rehearsal", key=None):
        return run(["sign-index", "--tree", tree_, "--keyset", keyset] + (["--key", key] if key else []))


    def verify_tree(name, tree_, want=0, text=None, red_case=False, unsigned=False, now=None, env=None, extra=None):
        argv = ["verify-tree", "--tree", tree_, "--keyset", "rehearsal"]
        argv += ["--unsigned"] if unsigned else []
        argv += ["--now", str(now)] if now is not None else []
        before = calls(root)
        p = run(argv, dict(env or {}, FAKE_ROOT=root))
        asked = calls(root)[len(before):]

        def judged():
            if "Traceback" in p.stderr + p.stdout:
                return False
            if want == 1 and "::error::" not in p.stdout:
                return False
            return extra(asked) if extra else True
        check(name, p, want, text, red_case, judged)
        return p


    def signed_tree(name, **kw):
        t = build_site(name, signed=False, extras=True, **kw)
        p = sign_index(t)
        if p.returncode:
            print(f"FATAL: sign-index of the fixture failed -- cannot measure\n{p.stdout}{p.stderr}")
            sys.exit(2)
        return t


    SIGS = [f"deb/dists/{c}/{n}" for c in CODENAMES for n in ("InRelease", "Release.gpg")] + \
           [f"rpm/{s}/repodata/repomd.xml.asc" for s in SLUGS]
    st = build_site("signidx", signed=False, extras=True)
    p = sign_index(st)

    def signed_as_assemble_wants():
        ok = all(os.path.isfile(os.path.join(st, n)) for n in SIGS)
        ok = ok and open(os.path.join(st, "deb/dists/trixie/InRelease"), "rb").read().startswith(b"-----BEGIN PGP SIGNED MESSAGE-----")
        ok = ok and not open(os.path.join(st, "deb/dists/trixie/Release.gpg"), "rb").read().startswith(b"-----")
        return ok and open(os.path.join(st, "rpm/fedora44/repodata/repomd.xml.asc"), "rb").read().startswith(b"-----BEGIN PGP SIGNATURE-----")
    check("41 sign-index: InRelease, Release.gpg (binary) and repomd.xml.asc (armored) for every index", p, 0,
          extra=signed_as_assemble_wants)

    verify_tree("42 verify-tree: the tree sign-index signed is rc 0 and its rpms are judged", st,
                extra=lambda asked: "--keyset rehearsal --verify-only" in asked)

    fetch_prev("43 fetch-prev: the tree sign-index signed mirrors whole", st,
               expect=lambda out: tree(out) == site_as_mirrored(st))

    rpm_only = os.path.join(root, "rpm-only.sec.asc")
    write(rpm_only, gpg(HOME_A, "--armor", "--export-secret-subkeys", ENV["S_RPM_FPR"] + "!").stdout)
    t = build_site("rpmonly", signed=False, extras=True)
    p = sign_index(t, key=rpm_only)
    check("44 RED sign-index: a key with S_RPM's secret but not S_IDX's is rc 1", p, 1, "No secret key", True,
          lambda: not any(os.path.exists(os.path.join(t, n)) for n in SIGS))

    t = build_site("lastfails", signed=False, extras=True)
    os.makedirs(os.path.join(t, "rpm/opensusetw/repodata/repomd.xml.asc.new"))  # the last signature cannot be written
    write(os.path.join(t, "deb/dists/trixie/InRelease.new"), "left over by an earlier run")
    p = sign_index(t)
    check("44c RED sign-index: when the last signature fails none is written", p, 1, "repomd.xml.asc", True,
          lambda: not any(os.path.exists(os.path.join(t, n)) for n in SIGS)
          and not os.path.exists(os.path.join(t, "deb/dists/trixie/InRelease.new")))

    foreign = os.path.join(root, "foreign.sec.asc")
    write(foreign, gpg(HOME_B, "--armor", "--export-secret-keys", KEY_B).stdout)
    t = build_site("foreignkey", signed=False, extras=True)
    p = sign_index(t, key=foreign)
    check("44b RED sign-index: a key holding a key outside the key set is rc 2", p, 2, "outside the key set", True,
          lambda: not any(os.path.exists(os.path.join(t, n)) for n in SIGS))

    p = sign_index(build_site("pkgsign", signed=False, extras=True), keyset="package-signing")
    check("45 RED sign-index: package-signing without --key is rc 2", p, 2, "--key", True)

    t = signed_tree("vt-keyb")
    shutil.move(sign_file(os.path.join(t, "deb/dists/trixie/Release"), "clear", FOREIGN), os.path.join(t, "deb/dists/trixie/InRelease"))
    verify_tree("46 RED verify-tree: InRelease signed by key B is rc 1", t, 1, "InRelease", True)

    t = signed_tree("vt-subkey")
    mp = os.path.join(t, "rpm/opensusetw/repodata/repomd.xml")
    shutil.move(sign_file(mp, "detach", OTHER_SUBKEY), mp + ".asc")
    verify_tree("47 RED verify-tree: repomd.xml signed by our rpm subkey is rc 1", t, 1, "not by the index signer", True)

    t = signed_tree("vt-pool")
    flip(os.path.join(t, "deb/pool/trixie/liblibrescrs5_5.0.0-1_amd64.deb"), 7)
    verify_tree("48 RED verify-tree: a changed byte in a pool deb is rc 1", t, 1, "sha256", True)

    t = signed_tree("vt-expired")
    verify_tree("49 RED verify-tree: Valid-Until in the past is rc 1", t, 1, "Valid-Until", True, now=VALID_UNTIL + 1)
    verify_tree("49b verify-tree: one second before Valid-Until is rc 0", t, now=VALID_UNTIL - 1)
    t = signed_tree("vt-novalid", valid_until=None)
    verify_tree("49c RED verify-tree: a Release without Valid-Until is rc 1", t, 1, "Valid-Until", True)

    verify_tree("50 RED verify-tree: an rpm signature that does not verify is rc 1", st, 1, "rpm signatures", True,
                env={"FAKE_SIGN_RC": "1"})
    verify_tree("50b RED verify-tree: pkg-sign.sh cannot judge stays rc 2", st, 2, None, True, env={"FAKE_SIGN_RC": "2"})

    t = signed_tree("vt-repomd")
    with open(os.path.join(t, "rpm/fedora43/repodata/repomd.xml"), "a") as f:
        f.write("\n")
    verify_tree("51 RED verify-tree: repomd.xml changed after it was signed is rc 1", t, 1, "repomd.xml.asc", True)

    t = build_site("vt-relhash", signed=False, extras=True)
    rp = os.path.join(t, "deb/dists/resolute/Release")
    pk_hash = sha(open(os.path.join(t, "deb/dists/resolute/main/binary-amd64/Packages"), "rb").read())
    write(rp, open(rp).read().replace(pk_hash, sha(b"another Packages")))
    p = sign_index(t)
    verify_tree("52 RED verify-tree: a hash in Release wrong before signing is rc 1", t, 1, "sha256", True,
                extra=lambda asked: p.returncode == 0)

    t = build_site("vt-unsigned", signed=False, extras=True)
    verify_tree("53 verify-tree --unsigned: an unsigned tree's hash chain is rc 0, no signature asked", t, unsigned=True,
                extra=lambda asked: "sign " not in asked)
    verify_tree("54 RED verify-tree: an unsigned tree without --unsigned is rc 1", t, 1, "InRelease", True)
    flip(os.path.join(t, "deb/dists/trixie/main/binary-amd64/Packages.xz"), 3)
    verify_tree("55 RED verify-tree --unsigned: a changed byte in Packages.xz is rc 1", t, 1, "Packages.xz", True, unsigned=True)

    t = signed_tree("vt-alias")
    write(os.path.join(t, "librescrs-archive-keyring-trixie.deb"), b"not the indexed keyring")
    verify_tree("56 RED verify-tree: a stable alias that is no indexed package is rc 1", t, 1,
                "librescrs-archive-keyring-trixie.deb", True)

    t = signed_tree("vt-noslug")
    shutil.rmtree(os.path.join(t, "rpm/fedora44"))
    verify_tree("57 RED verify-tree: a tree without an rpm slug is rc 1", t, 1, "fedora44", True)

    t = signed_tree("vt-key")
    write(os.path.join(t, "rpm/fedora43/repodata/repomd.xml.key"), CERT + b"\n")
    verify_tree("57b RED verify-tree: repomd.xml.key that is not the key set's certificate is rc 1", t, 1, "repomd.xml.key", True)

    verify_tree("58 RED verify-tree: no tree is rc 2", os.path.join(root, "no-such-tree"), 2, "cannot judge", True)

    # ---- hardening: time zones, a missing gpgconf, InRelease == Release, nested rpms
    for label, vu in (("59 RED verify-tree: Valid-Until in -0000 (no zone) is rc 1", "-0000"),
                      ("59b RED verify-tree: Valid-Until without a zone is rc 1", "")):
        t = build_site("vt-tz" + vu, signed=False, extras=True)
        for c in CODENAMES:
            rp = os.path.join(t, f"deb/dists/{c}/Release")
            write(rp, open(rp).read().replace(RFC(VALID_UNTIL), RFC(VALID_UNTIL).replace(" +0000", (" " + vu).rstrip())))
        p = sign_index(t)
        verify_tree(label, t, 1, "Valid-Until has no timezone", True, extra=lambda asked: p.returncode == 0)

    nogpgconf = os.path.join(root, "bin-nogpgconf")
    os.makedirs(nogpgconf)
    for tool_ in ("gpg", "gpgv", "zstd", "bash", "ls"):
        os.symlink(shutil.which(tool_), os.path.join(nogpgconf, tool_))
    tmp_empty, tmp_ro = os.path.join(root, "tmp-empty"), os.path.join(root, "tmp-ro")
    os.makedirs(tmp_empty)
    os.makedirs(tmp_ro)
    os.chmod(tmp_ro, 0o500)  # an --unsigned run makes no gpg home, so it needs no writable TMPDIR
    t = build_site("vt-nogpgconf", signed=False, extras=True)
    verify_tree("60 verify-tree --unsigned without gpgconf on PATH: rc 0, no gpg home made", t, unsigned=True,
                env={"PATH": nogpgconf, "TMPDIR": tmp_ro}, extra=lambda asked: os.listdir(tmp_ro) == [])
    os.chmod(tmp_ro, 0o700)
    verify_tree("60b verify-tree without gpgconf on PATH: the signed path is rc 0, not a traceback", st,
                env={"PATH": nogpgconf, "TMPDIR": tmp_empty}, extra=lambda asked: os.listdir(tmp_empty) == [])

    def release_differs_from_inrelease(name, sign_tree):
        t = sign_tree(name)
        for c in ("resolute",):
            rt = open(os.path.join(t, f"deb/dists/{c}/Release")).read()
            resign(t, c, rt.replace("Origin: LibreSCRS", "Origin: Someone Else"), rt)
        return t
    t = release_differs_from_inrelease("vt-originonly", signed_tree)
    verify_tree("61 RED verify-tree: Release differing from InRelease only in Origin is rc 1", t, 1,
                "does not sign exactly the bytes", True)
    t = release_differs_from_inrelease("fp-originonly", build_site)
    fetch_prev("61b RED fetch-prev: Release differing from InRelease only in Origin is rc 1", t, 1,
               "does not sign exactly the bytes", True)

    t = build_site("si-trailing", signed=False, extras=True)
    rp = os.path.join(t, "deb/dists/trixie/Release")
    write(rp, open(rp).read().replace("Origin: LibreSCRS\n", "Origin: LibreSCRS \n"))
    p = sign_index(t)
    check("62 RED sign-index: a Release whose clearsigned text is not its bytes (trailing blank) is rc 1", p, 1,
          "not the bytes of Release", True, lambda: not any(os.path.exists(os.path.join(t, n)) for n in SIGS))

    t = signed_tree("vt-nested", rpm_dir="Packages/l/")
    verify_tree("63 verify-tree: an rpm primary names below the top of its slug is judged by pkg-sign", t,
                extra=lambda asked: "libls-5.0.0-1.noarch.fedora44.rpm" in asked)

    # ---- the action run blocks that decide alone: the published output, the key refusals
    def output_is(want):
        return lambda d: open(os.path.join(d, "github-output")).read() == want

    def releases_none(d):
        write(os.path.join(d, "rel", "NONE"), "no code repository has a release tag\n")
        return "rel"

    def prev_empty(d):
        write(os.path.join(d, "prev", "EMPTY"), "HTTP 404: no published generation\n")
        return "prev"

    def prev_mirror(d):
        write(os.path.join(d, "prev", "deb", "dists", "trixie", "InRelease"), "a published generation\n")
        return "prev"

    action_step("74 action assemble: NONE and EMPTY -- nothing released, nothing published -- is published=false, rc 0",
                {"STEP": "assemble", "MODE": "publish", "TREE": "tree", "RELEASES": releases_none,
                 "PREV": prev_empty}, 0, "not yet published",
                expect=lambda d: output_is("published=false\n")(d) and not os.path.exists(os.path.join(d, "tree")),
                perturb=('if [ -e "$PREV/EMPTY" ]; then', 'if false; then'))
    action_step("75 RED action assemble: NONE beside a published generation is rc 1, no published output",
                {"STEP": "assemble", "MODE": "publish", "TREE": "tree", "RELEASES": releases_none,
                 "PREV": prev_mirror}, 1, "a published release vanished", True, output_is(""),
                perturb=('err "no release is left, but $LIVE_URL publishes a generation -- a published release vanished"\n'
                         '        exit 1', 'echo "published=false" >> "$GITHUB_OUTPUT"; exit 0'))
    action_step("76 RED action assemble: NONE and a prev that is neither mirror nor EMPTY is rc 2, no published output",
                {"STEP": "assemble", "MODE": "publish", "TREE": "tree", "RELEASES": releases_none,
                 "PREV": "no-such-prev"}, 2, "is neither a fetch-prev mirror nor EMPTY", True, output_is(""),
                perturb=('if [ -e "$PREV/EMPTY" ]; then', 'if [ ! -e "$PREV" ] || [ -e "$PREV/EMPTY" ]; then'))

    # A release set assemble takes whole: the keyring and release packages of
    # packages 1.0.0, indexed by a fake pkg-repo-index.sh (no Docker).
    FAKE_INDEX = script("fake-index", r"""#!/usr/bin/env bash
case "$1" in
  fields) cd "$2" && find . -name '*.deb' | while read -r f; do
      case "$f" in *.debian13.deb) v='1.0.0-1~deb13' ;; *) v='1.0.0-1~ubuntu26.04' ;; esac
      printf '%s	librescrs-archive-keyring	%s	all
' "${f#./}" "$v"; done ;;
  deb) d="$2/deb/dists/$3/main/binary-amd64"; mkdir -p "$d"; echo "Package: x" > "$d/Packages"; echo x > "$d/Packages.xz" ;;
  rpm) mkdir -p "$2/rpm/$3/repodata"; echo '<repomd/>' > "$2/rpm/$3/repodata/repomd.xml" ;;
  *) exit 9 ;;
esac
""")

    def releases_keyrings(d):
        b = os.path.join(d, "rel", "packages", "1.0.0")
        for n in ("librescrs-archive-keyring_1.0.0-1~deb13_all.debian13.deb",
                  "librescrs-archive-keyring_1.0.0-1~ubuntu26.04_all.ubuntu2604.deb",
                  "librescrs-release-1.0.0-1.fc43.noarch.fedora43.rpm",
                  "librescrs-release-1.0.0-1.noarch.opensusetw.rpm", "KEYS"):
            write(os.path.join(b, n), n)
        return "rel"

    action_step("77 action assemble: a release set assembles, published=true, rc 0",
                {"STEP": "assemble", "MODE": "rehearse", "TREE": "tree", "RELEASES": releases_keyrings,
                 "PREV": prev_empty, "PKG_REPO_INDEX": FAKE_INDEX}, 0,
                expect=lambda d: output_is("published=true\n")(d)
                and os.path.isfile(os.path.join(d, "tree", "librescrs-release-fedora.noarch.rpm")),
                perturb=('echo "published=true" >> "$GITHUB_OUTPUT" ;;', ';;'))

    def unsigned_tree(d):
        shutil.copytree(build_site("act-" + os.path.basename(d), signed=False), os.path.join(d, "tree"))
        return "tree"

    def nothing_signed(d):
        return not any(os.path.exists(os.path.join(d, "tree", n)) for n in SIGS)

    action_step("78 RED action sign-index: a rehearsal handed a key is rc 1, nothing signed",
                {"STEP": "sign-index", "MODE": "rehearse", "TREE": unsigned_tree, "KEY": "a secret key"}, 1,
                "a rehearsal received the real index key -- refusing", True, nothing_signed,
                perturb=('[ -z "$key" ] || { err "a rehearsal received the real index key -- refusing"; exit 1; }', ':'))
    action_step("79 RED action sign-index: a publish with keyset rehearsal is rc 2, nothing signed",
                {"STEP": "sign-index", "MODE": "publish", "KEYSET": "rehearsal", "TREE": unsigned_tree,
                 "KEY": "a secret key"}, 2, "a publish signs with package-signing, not 'rehearsal'", True, nothing_signed,
                unreached="pkg-repo: ",  # sign-index never ran: the 2 is the refusal's
                perturb=('[ -z "$KEYSET" ] || [ "$KEYSET" = package-signing ] \\\n'
                         '          || { err "a publish signs with package-signing, not \'$KEYSET\'"; exit 2; }', ':'))
    action_step("80 RED action sign-index: a rehearsal with keyset package-signing is rc 2, nothing signed",
                {"STEP": "sign-index", "MODE": "rehearse", "KEYSET": "package-signing", "TREE": unsigned_tree}, 2,
                "a rehearsal signs with rehearsal, not 'package-signing'", True, nothing_signed,
                perturb=('[ -z "$KEYSET" ] || [ "$KEYSET" = rehearsal ] \\\n'
                         '          || { err "a rehearsal signs with rehearsal, not \'$KEYSET\'"; exit 2; }', ':'))

    def not_signed_by_pkg_sign(d):
        return not os.path.exists(os.path.join(d, "pkg-sign.log"))

    action_step("81 RED action pkg-sign: a rehearsal handed a key is rc 1, pkg-sign.sh never runs",
                {"MODE": "rehearse", "PKGS": "pkgs", "KEY": "a secret key"}, 1,
                "a rehearsal received the real key -- refusing", True, not_signed_by_pkg_sign, action="pkg-sign",
                perturb=('[ -z "$KEY" ] || { echo "::error::a rehearsal received the real key -- refusing"; exit 1; }', ':'))
    action_step("82 RED action pkg-sign: a publish without a key is rc 1, pkg-sign.sh never runs",
                {"MODE": "publish", "PKGS": "pkgs"}, 1, "publish without the package-signing key", True,
                not_signed_by_pkg_sign, action="pkg-sign",
                perturb=('[ -n "$KEY" ] || { echo "::error::publish without the package-signing key"; exit 1; }', ':'))

    # ---- watch
    def watch(name, site, want, text=None, red_case=False, status=None, env=None):
        srv, url = serve(site, status)
        try:
            # gh answers from a GitHub where only the packages repository has
            # released, unless the case says otherwise
            p = run(["watch", "--url", url, "--keyset", "rehearsal", "--min-days", "14"],
                    dict({"FAKE_ROOT": unreleased}, **(env or {})))
        finally:
            srv.shutdown()
            srv.server_close()
        check(name, p, want, text, red_case,
              lambda: "Traceback" not in p.stdout + p.stderr and (want != 1 or "::error::" in p.stdout))

    unreleased = fixture("watch-unreleased", tags=("4.2.0",))
    released = fixture("watch-released", tags=("4.2.0",))
    write(os.path.join(released, "LibreKDE", "releases.json"), rel("5.0.0"))
    w20 = build_site("w20", valid_until=NOW + 20 * 86400)
    watch("64 watch: Valid-Until 20 days ahead is rc 0", w20, 0, "more than 14 days ahead")
    watch("65 RED watch: Valid-Until 10 days ahead is rc 1", build_site("w10", valid_until=NOW + 10 * 86400), 1,
          "less than 14 days away", True)
    watch("66 RED watch: the clock is PKG_REPO_NOW -- 20 days ahead seen from 7 days later is rc 1", w20, 1,
          "less than 14 days away", True, env={"PKG_REPO_NOW": str(NOW + 7 * 86400)})
    watch("67 RED watch: an expired Valid-Until is rc 1", w20, 1, "is not later than now", True,
          env={"PKG_REPO_NOW": str(NOW + 21 * 86400)})
    watch("68 watch: HTTP 404 for trixie InRelease, no code repository released (packages has), is rc 0, not yet published",
          empty, 0, "not yet published")
    watch("68b RED watch: HTTP 404 once a code repository has released is rc 1, the repository is gone", empty, 1,
          "but LibreKDE released -- the published repository is gone", True, env={"FAKE_ROOT": released})
    watch("68c RED watch: HTTP 404 and the releases cannot be read is rc 2, not 'not yet published'", empty, 2,
          "cannot judge", True, env={"FAKE_ROOT": os.path.join(root, "no-such-github")})
    watch("69 RED watch: InRelease signed by our rpm subkey, not S_IDX, is rc 1",
          build_site("wrpm", {"InRelease-resolute": OTHER_SUBKEY}, valid_until=NOW + 20 * 86400), 1,
          "not by the index signer", True)
    t = build_site("wnores", valid_until=NOW + 20 * 86400)
    os.unlink(os.path.join(t, "deb/dists/resolute/InRelease"))
    watch("70 RED watch: resolute missing while trixie is published is rc 1", t, 1, "resolute/InRelease", True)
    watch("71 RED watch: HTTP 503 for trixie InRelease is rc 2, not 'not yet published'", w20, 2, "503", True,
          {"/deb/dists/trixie/InRelease": 503})
    watch("72 RED watch: no Valid-Until at all is rc 1", build_site("wnovu", valid_until=None), 1,
          "0 Valid-Until fields", True)
    t = build_site("wcodename", valid_until=NOW + 20 * 86400)
    shutil.copyfile(os.path.join(t, "deb/dists/resolute/InRelease"), os.path.join(t, "deb/dists/trixie/InRelease"))
    watch("73 RED watch: trixie serving resolute's (validly signed) InRelease is rc 1", t, 1,
          "Codename ['resolute'], want exactly trixie", True)

finally:
    for h in homes:
        subprocess.run(["gpgconf", "--kill", "all"], env=dict(os.environ, GNUPGHOME=h), capture_output=True)
        shutil.rmtree(h, ignore_errors=True)

shutil.rmtree(root, ignore_errors=True)
print(f"selftest: {cases} cases, {red} red-proved")
sys.exit(1 if failed else 0)
