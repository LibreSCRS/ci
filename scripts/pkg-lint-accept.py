#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""pkg-lint-accept.py -- judge lintian / rpmlint output against lint-accepted/.

Usage:
  pkg-lint-accept.py --slug S --accepted DIR --linted PKG[,PKG...] \
                     [--lintian FILE] [--rpmlint FILE]

A finding is every lintian error or warning (lintian --fail-on error,warning)
and every rpmlint ERROR. rpmlint warnings are printed but not judged: they are
dominated by distribution-policy checks (Fedora's crypto policy, gethostbyname
in bundled curl, ...) that describe how a distribution builds its own
archive, not a defect of a package published as a release file, and the
original plan for this gate was "rpmlint without errors". A finding is
accepted only by a row in lint-accepted/<package>.txt:

    <tool> <slug-glob> <tag> <context-glob> -- <reason>

    lintian * embedded-library * -- OpenSSL, curl and OpenSC are linked in on
                                    purpose; see README-bundling.md

and the list is bounded, because an unbounded accept list is a lint gate that
has been switched off one line at a time:

  * at most CAP rows per package;
  * every row carries a reason of at least MIN_REASON characters;
  * a row for any tag outside the embedded-library family also carries who
    decided it: "[owner YYYY-MM-DD]" (the owner's decision, e.g. SPEC D18) or
    "[session YYYY-MM-DD]" (a working-session decision recorded in the plan,
    pending the owner's review) -- the family is the one acceptance the
    bundling policy already decided;
  * a row that applies to this run (its tool ran, its slug matches, its
    package was linted) and matches no finding is RED: the defect it excused
    is gone, and the row would silently excuse the next one.

Exit codes: 0 every finding accepted and every applicable row used, 1 an
unaccepted finding / a stale, malformed or over-cap row, 2 cannot judge
(no package linted, no tool output, an unreadable file). An empty tool output
is a clean run, so the caller proves the tool ran, not this script.
"""
import argparse
import fnmatch
import os
import re
import sys

CAP = 5
MIN_REASON = 15
OWNER = re.compile(r"\[(owner|session) \d{4}-\d{2}-\d{2}\]")
FAMILY = re.compile(r"^embedded-library")
JUDGED = {"lintian": ("E", "W"), "rpmlint": ("E",)}

LINTIAN = re.compile(r"^([EWIPXOC]): ([^\s:]+)(?: \([a-z]+\))?: (\S+)\s*(.*)$")
RPMLINT = re.compile(r"^([^\s:]+?)(?:\.(?:x86_64|noarch|i686|aarch64|src))?:\s+([EW]): (\S+)\s*(.*)$")


def parse(tool, path):
    """-> list of (tool, pkg, sev, tag, context); None when unreadable."""
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    out = []
    for line in text.splitlines():
        m = (LINTIAN if tool == "lintian" else RPMLINT).match(line.rstrip())
        if not m:
            continue
        if tool == "lintian":
            sev, pkg, tag, ctx = m.groups()
        else:
            pkg, sev, tag, ctx = m.groups()
        out.append((tool, pkg, sev, tag, ctx.strip()))
    return out


def load_rows(accepted, pkg, problems):
    path = os.path.join(accepted, pkg + ".txt")
    rows = []
    if not os.path.exists(path):
        return rows
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        where = f"lint-accepted/{pkg}.txt:{n}"
        if " -- " not in line:
            problems.append(f"{where}: no ' -- <reason>'")
            continue
        head, reason = line.split(" -- ", 1)
        f = head.split()
        if len(f) != 4 or f[0] not in ("lintian", "rpmlint"):
            problems.append(f"{where}: want '<lintian|rpmlint> <slug-glob> <tag> <context-glob> -- <reason>'")
            continue
        if len(reason.strip()) < MIN_REASON:
            problems.append(f"{where}: reason shorter than {MIN_REASON} characters")
            continue
        if not FAMILY.match(f[2]) and not OWNER.search(reason):
            problems.append(f"{where}: {f[2]} is outside the embedded-library family and carries no [owner|session YYYY-MM-DD]")
            continue
        rows.append({"where": where, "tool": f[0], "slug": f[1], "tag": f[2], "ctx": f[3], "used": 0})
    if len(rows) > CAP:
        problems.append(f"lint-accepted/{pkg}.txt: {len(rows)} rows, the cap is {CAP} per package")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slug", required=True)
    ap.add_argument("--accepted", required=True)
    ap.add_argument("--linted", required=True)
    ap.add_argument("--lintian")
    ap.add_argument("--rpmlint")
    a = ap.parse_args()

    linted = sorted({p for p in a.linted.split(",") if p})
    if not linted:
        print("pkg-lint-accept: no package was linted -- cannot judge", file=sys.stderr)
        return 2
    if not os.path.isdir(a.accepted):
        print(f"pkg-lint-accept: {a.accepted} is not a directory -- cannot judge", file=sys.stderr)
        return 2
    ran, findings = [], []
    for tool, path in (("lintian", a.lintian), ("rpmlint", a.rpmlint)):
        if not path:
            continue
        got = parse(tool, path)
        if got is None:
            print(f"pkg-lint-accept: cannot read {path} -- cannot judge", file=sys.stderr)
            return 2
        ran.append(tool)
        findings += got
    if not ran:
        print("pkg-lint-accept: no tool output given -- cannot judge", file=sys.stderr)
        return 2

    problems = []
    rows = {p: load_rows(a.accepted, p, problems) for p in linted}
    bad = []
    counted = 0
    notes = 0
    for tool, pkg, sev, tag, ctx in findings:
        if sev not in JUDGED[tool]:
            if sev == "W":
                notes += 1
                print(f"note      {tool} {sev} {pkg}: {tag} {ctx}")
            continue
        counted += 1
        hit = None
        for r in rows.get(pkg, []):
            if (r["tool"] == tool and fnmatch.fnmatchcase(a.slug, r["slug"])
                    and fnmatch.fnmatchcase(tag, r["tag"]) and fnmatch.fnmatchcase(ctx, r["ctx"])):
                hit = r
                break
        if hit:
            hit["used"] += 1
            print(f"accepted  {tool} {sev} {pkg}: {tag} {ctx}  ({hit['where']})")
        else:
            bad.append(f"{tool} {sev} {pkg}: {tag} {ctx}")
    for p, rs in rows.items():
        for r in rs:
            if r["tool"] in ran and fnmatch.fnmatchcase(a.slug, r["slug"]) and r["used"] == 0:
                problems.append(f"{r['where']}: matches no finding on {a.slug} -- the defect it excused is gone; delete the row")
    for b in bad:
        print(f"FINDING   {b}")
    for p in problems:
        print(f"ROW       {p}")
    print(f"pkg-lint-accept: {a.slug}: {counted} E/W finding(s) over {len(linted)} package(s) "
          f"with {'+'.join(ran)}; {len(bad)} unaccepted, {len(problems)} row problem(s); {notes} unjudged warning(s)")
    return 1 if bad or problems else 0


if __name__ == "__main__":
    sys.exit(main())
