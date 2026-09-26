#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Self-test for pkg-lint-accept.py: accepted findings pass, and an unaccepted
finding, a stale row, a row with no reason, an unapproved non-bundling row and
an over-cap list are each red."""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "pkg-lint-accept.py")
cases = red = 0
failed = False

LINTIAN_BUNDLED = """\
W: liblibrescrs5: embedded-library usr/lib/x86_64-linux-gnu/libLibreSCRS_Core.so.5.0.0: openssl
I: liblibrescrs5: spelling-error-in-description teh the
"""
RPMLINT_BUNDLED = """\
librescrs-middleware.x86_64: W: embedded-library /usr/lib64/libLibreSCRS_Core.so.5.0.0 openssl
librescrs-middleware.x86_64: W: no-manual-page-for-binary eid-sod-verify
2 packages and 0 specfiles checked; 0 errors, 2 warnings
"""
ROW = "lintian * embedded-library * -- OpenSSL is linked statically on purpose (README-bundling.md)\n"


def run(name, want, files, slug="debian13", linted="liblibrescrs5", lintian=None, rpmlint=None):
    global cases, red, failed
    cases += 1
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR", "/var/tmp")) as d:
        acc = os.path.join(d, "lint-accepted")
        os.mkdir(acc)
        for fn, text in files.items():
            with open(os.path.join(acc, fn), "w") as f:
                f.write(text)
        args = [sys.executable, TOOL, "--slug", slug, "--accepted", acc, "--linted", linted]
        for tool, text in (("lintian", lintian), ("rpmlint", rpmlint)):
            if text is not None:
                p = os.path.join(d, tool + ".txt")
                with open(p, "w") as f:
                    f.write(text)
                args += ["--" + tool, p]
        r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode == want:
        print(f"ok   {name} (rc={r.returncode})")
        if r.returncode == 1:
            red += 1
    else:
        print(f"FAIL {name}: want rc={want}, got rc={r.returncode}")
        print("  | " + (r.stdout + r.stderr).replace("\n", "\n  | "))
        failed = True


run("clean lintian run with no rows", 0, {}, lintian="")
run("bundling finding accepted by its row", 0, {"liblibrescrs5.txt": ROW}, lintian=LINTIAN_BUNDLED)
run("info-level output is not a finding", 0, {"liblibrescrs5.txt": ROW}, lintian=LINTIAN_BUNDLED)
run("unaccepted warning is red", 1, {}, lintian=LINTIAN_BUNDLED)
run("stale row (no finding left) is red", 1, {"liblibrescrs5.txt": ROW}, lintian="")
run("row for another slug does not apply", 0,
    {"liblibrescrs5.txt": ROW.replace("lintian *", "lintian ubuntu*")}, lintian="")
run("row for a tool that did not run does not apply", 0,
    {"liblibrescrs5.txt": ROW.replace("lintian *", "rpmlint *")}, lintian="")
run("row without a reason is red", 1,
    {"liblibrescrs5.txt": "lintian * embedded-library *\n"}, lintian=LINTIAN_BUNDLED)
run("row with a too-short reason is red", 1,
    {"liblibrescrs5.txt": "lintian * embedded-library * -- bundled\n"}, lintian=LINTIAN_BUNDLED)
run("context glob that does not match is red", 1,
    {"liblibrescrs5.txt": ROW.replace("embedded-library *", "embedded-library *curl*")}, lintian=LINTIAN_BUNDLED)
OTHER = "W: liblibrescrs5: package-name-doesnt-match-sonames libLibreSCRS-Core5\n"
run("non-bundling tag without owner approval is red", 1,
    {"liblibrescrs5.txt": "lintian * package-name-doesnt-match-sonames * -- one runtime package on purpose\n"},
    lintian=OTHER)
run("non-bundling tag with owner approval passes", 0,
    {"liblibrescrs5.txt": "lintian * package-name-doesnt-match-sonames * -- one runtime package on purpose [owner 2026-09-26]\n"},
    lintian=OTHER)
many = "".join(f"lintian * embedded-library *lib{i}* -- bundled library number {i} on purpose\n" for i in range(6))
many_out = "".join(f"W: liblibrescrs5: embedded-library /usr/lib/lib{i}.so x\n" for i in range(6))
run("six rows exceed the cap of five", 1, {"liblibrescrs5.txt": many}, lintian=many_out)
run("rpmlint errors are judged", 1, {},
    slug="fedora43", linted="librescrs-middleware",
    rpmlint="librescrs-middleware.x86_64: E: incorrect-fsf-address /usr/share/licenses/x/LICENSE\n")
run("rpmlint warnings are not judged", 0, {},
    slug="fedora43", linted="librescrs-middleware", rpmlint=RPMLINT_BUNDLED)
run("a row for an rpmlint warning is stale (warnings are never findings)", 1, {"librescrs-middleware.txt":
    "rpmlint * embedded-library * -- OpenSSL is linked statically on purpose (README-bundling.md)\n"},
    slug="fedora43", linted="librescrs-middleware", rpmlint=RPMLINT_BUNDLED)
run("rpmlint error accepted by an approved row", 0, {"librescrs-middleware.txt":
    "rpmlint fedora* spelling-error *eMRTD* -- eMRTD is the ICAO name of the document, not a misspelling [owner 2026-09-26]\n"},
    slug="fedora43", linted="librescrs-middleware",
    rpmlint="librescrs-middleware.x86_64: E: spelling-error ('eMRTD', '%description -l en_US eMRTD -> emoted')\n")
run("no linted package cannot be judged", 2, {}, linted="", lintian="")
run("no tool output cannot be judged", 2, {})

if failed:
    print("pkg-lint-accept.selftest: FAILED")
    sys.exit(1)
print(f"selftest: {cases} cases, {red} red-proved")
