#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
"""Canonical-declaration gate.

Every name in ``canonical-types.tsv`` must be declared at the site the registry
names, and nowhere else -- except at a site the same row lists as a sanctioned
mirror.  A mirror on the record is a decision someone made and signed; an
unlisted second declaration is duplication coming back.

A sanctioned mirror also has to say so at the declaration itself::

    // MIRROR-OF: <canonical path> -- <reason>

so that a reader who lands on the mirror learns it is one without leaving the
file, and so that deleting the registry row and deleting the marker are two
separate acts rather than one silent one.

Three failures, not one.  A second declaration is a failure; a mirror with no
marker is a failure; and a canonical site that has stopped declaring its own
type is a failure too -- that last one is exactly the shape a careless "fix" to
this gate produces, so it is named rather than assumed impossible.

Exit codes: 0 clean, 1 violations found, 2 the gate could not measure (which is
never to be read as a pass).
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

REPOS = [
    "LibreMiddleware",
    "LibreAgent",
    "LibreLinux",
    "LibreCelik",
    "LibreKDE",
    "LibreDarwin",
    "LibreMac",
]

SOURCE_EXT = (".h", ".hpp", ".hh", ".c", ".cc", ".cpp", ".cxx", ".mm", ".m", ".swift")
SKIP_FRAGMENTS = ("thirdparty/", "third_party/", "install/", "install-", "/build/")

MIRROR_MARK = "MIRROR-OF:"


class Fatal(Exception):
    """The gate could not measure.  Exit 2, never 0."""


def repo_root():
    """The consumer's checkout: REPO_ROOT, else $GITHUB_WORKSPACE, else the git
    checkout around the current directory; None when there is none. Never this
    file's own location -- the gate lives in one repository and judges another."""
    root = os.environ.get("REPO_ROOT") or os.environ.get("GITHUB_WORKSPACE")
    if not root:
        try:
            out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                                 capture_output=True, text=True, check=False)
        except OSError:
            return None
        root = out.stdout.strip() if out.returncode == 0 else ""
    return os.path.abspath(root) if root and os.path.isdir(root) else None


def checkouts(workspace_arg, repo_arg):
    """{repository name: checkout path} for this run.

    With --workspace, the side-by-side clones under it: every repository, or
    only --repo. Without it, the one checkout being judged, under the name the
    registry knows it by: --repo, else the repository part of
    $GITHUB_REPOSITORY, else the checkout's directory name. A CI checkout
    does not have to sit in a directory named after its repository, so the
    directory name is the last resort, not the rule."""
    if workspace_arg:
        workspace = os.path.abspath(workspace_arg)
        if repo_arg:
            path = os.path.join(workspace, repo_arg)
            if not os.path.isdir(path):
                raise Fatal(f"no such checkout: {path}")
            return {repo_arg: path}, {repo_arg}
        return {r: os.path.join(workspace, r) for r in REPOS}, set(REPOS)
    root = repo_root()
    if root is None:
        raise Fatal("no repository to judge -- set REPO_ROOT, pass --workspace, "
                    "or run inside a checkout")
    name = (repo_arg or os.environ.get("GITHUB_REPOSITORY", "").rpartition("/")[2]
            or os.path.basename(root))
    return {name: root}, {name}


def locate(where, rel):
    """A registry path (<repository>/<path>) on disk, or None."""
    repo, _, rest = rel.partition("/")
    base = where.get(repo)
    return os.path.join(base, rest) if base else None


def parse_registry(path: str):
    """Rows are ``name<TAB>canonical[<TAB>mirrors]``.

    ``name`` may carry a kind prefix: ``func:`` for a function, ``dup:`` for a
    whole-file duplicate group that the duplicate-body scanner reads and this
    gate skips. No prefix means a type (class/struct/enum/union/alias).
    """
    rows = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            cols = [c.strip() for c in raw.rstrip("\n").split("\t") if c.strip() != ""]
            if len(cols) < 2:
                raise Fatal(f"{path}:{lineno}: a registry row needs a name and a canonical site")
            name, canon = cols[0], cols[1]
            mirrors = []
            unmarked = set()
            if len(cols) >= 3 and cols[2] != "-":
                for raw_mirror in cols[2].split(","):
                    mirror = raw_mirror.strip()
                    if not mirror:
                        continue
                    # A leading ~ means: recorded here, but no marker is asked
                    # of the file. Reserved for trees this project does not
                    # author -- another platform's client, a vendored third
                    # party -- where adding a comment is editing someone
                    # else's source.
                    if mirror.startswith("~"):
                        mirror = mirror[1:].strip()
                        unmarked.add(mirror)
                    mirrors.append(mirror)
            kind = "type"
            if ":" in name:
                maybe, rest = name.split(":", 1)
                if maybe in ("type", "func", "dup"):
                    kind, name = maybe, rest
            rows.append({"kind": kind, "name": name, "canonical": canon,
                         "mirrors": mirrors, "unmarked": unmarked,
                         "lineno": lineno})
    return rows


def tracked_sources(where):
    """``git ls-files`` per repo, and the return code is checked every time.

    The workspace root is a parent holding side-by-side clones, not a git
    repository.  A bare ``git ls-files`` run there exits 128 with empty output,
    and empty output through this gate reads as "nothing declared anywhere,
    everything passes".  That is the exact false green this gate exists to
    prevent, so a non-zero return code is fatal rather than skipped.
    """
    found = []
    for repo, repo_path in where.items():
        if not os.path.isdir(repo_path):
            continue
        proc = subprocess.run(["git", "-C", repo_path, "ls-files"],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            raise Fatal(f"git -C {repo_path} ls-files exited {proc.returncode}: "
                        f"{proc.stderr.strip()}")
        names = [n for n in proc.stdout.split("\n") if n]
        if not names:
            raise Fatal(f"git -C {repo_path} ls-files listed no files at all")
        for rel in names:
            if not rel.endswith(SOURCE_EXT):
                continue
            if any(frag in "/" + rel for frag in SKIP_FRAGMENTS):
                continue
            found.append((f"{repo}/{rel}", os.path.join(repo_path, rel)))
    if not found:
        raise Fatal("no tracked source files found in any repository")
    return found


def type_pattern(name: str) -> re.Pattern:
    esc = re.escape(name)
    return re.compile(
        r"^\s*(?:template\s*<[^>]*>\s*)?"
        r"(?:(?:class|struct|union|enum(?:\s+class|\s+struct)?)\s+"
        r"(?:[A-Z_][A-Za-z0-9_]*\s+)?" + esc + r"\b(?!\s*(?:[;,)]|::))"
        r"|using\s+" + esc + r"\s*="
        r"|typedef\s+.*\b" + esc + r"\s*;)"
    )


def func_pattern(name: str) -> re.Pattern:
    """A function DEFINITION at the start of a line.

    Deliberately anchored: a call site sits inside a body, after ``=``,
    ``return``, ``.`` or ``->``, while a definition begins its own line with
    its return type.

    Declarations are not owners.  A prototype in a header and the body in the
    matching source file are one implementation written down twice because the
    language requires it, not a second copy of anything -- so a line that ends
    in a semicolon is skipped by :func:`declaration_sites`, and the name is
    owned wherever its body is.
    """
    esc = re.escape(name)
    return re.compile(
        r"^\s*(?!return\b)(?!//)(?!\*)"
        r"(?:\[\[[^\]]*\]\]\s*)*"
        r"(?:[A-Za-z_][\w:<>,\s\*&\[\]]*?\s[\*&]?\s*)?"
        r"(?:[A-Za-z_][\w]*::)*" + esc + r"\s*\("
    )


def declaration_sites(rows, files):
    """Where each registered name is declared.  One pass over each file."""
    matchers = []
    for row in rows:
        if row["kind"] == "dup":
            continue
        pat = func_pattern(row["name"]) if row["kind"] == "func" else type_pattern(row["name"])
        matchers.append((row, pat))
        row["sites"] = []
    for rel, full in files:
        try:
            with open(full, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for idx, line in enumerate(lines, 1):
            stripped = line.lstrip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            ends_statement = line.rstrip().endswith(";")
            for row, pat in matchers:
                if row["name"] not in line or not pat.match(line):
                    continue
                if row["kind"] == "func" and ends_statement:
                    continue  # a prototype is not a second implementation
                row["sites"].append((rel, idx))
    return rows


def has_mirror_mark(where, rel: str, canonical: str) -> bool:
    path = locate(where, rel)
    if path is None:
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return False
    for line in text.splitlines():
        if MIRROR_MARK in line and canonical in line:
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description="canonical declaration registry gate")
    ap.add_argument("--workspace", default=None,
                    help="workspace root holding the side-by-side clones; without "
                         "it, the one checkout REPO_ROOT names is scanned")
    ap.add_argument("--repo", default=None,
                    help="single-repo subset: only this checkout is scanned; "
                         "without --workspace, the name the checkout is known by")
    ap.add_argument("--registry", default=None,
                    help="path to the registry (default: canonical-types.tsv "
                         "beside this script -- the registry is shared data)")
    args = ap.parse_args()

    registry = args.registry or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                             "canonical-types.tsv")
    try:
        if not os.path.isfile(registry):
            raise Fatal(f"registry not found: {registry}")
        rows = parse_registry(registry)
        where, scanned = checkouts(args.workspace, args.repo)
        files = tracked_sources(where)
    except Fatal as exc:
        print(f"FATAL  {exc}", file=sys.stderr)
        print("EXIT=2")
        return 2

    declaration_sites(rows, files)

    bad = 0
    registered = 0
    for row in rows:
        if row["kind"] == "dup":
            continue
        registered += 1
        name, canon, mirrors = row["name"], row["canonical"], row["mirrors"]
        allowed = {canon, *mirrors}
        sites = row["sites"]

        canon_repo = canon.split("/", 1)[0]
        if canon_repo in scanned and not any(rel == canon for rel, _ in sites):
            print(f"MISSING       {name}: canonical site {canon} declares no such name")
            bad += 1

        for rel, line in sites:
            if rel not in allowed:
                print(f"OFF-REGISTRY  {name} declared at {rel}:{line} (canonical: {canon})")
                bad += 1

        for mirror in mirrors:
            if mirror.split("/", 1)[0] not in scanned:
                continue
            if not os.path.isfile(locate(where, mirror) or ""):
                print(f"MIRROR-GONE   {name}: registered mirror {mirror} does not exist")
                bad += 1
                continue
            if mirror in row["unmarked"]:
                continue
            if not has_mirror_mark(where, mirror, canon):
                print(f"MIRROR-UNMARKED {name}: {mirror} carries no "
                      f"'{MIRROR_MARK} {canon}' line")
                bad += 1

    scope = ("all checkouts" if args.workspace and not args.repo
             else "--repo " + ", ".join(sorted(scanned)))
    print(f"\n{registered} registered names, {bad} violations ({scope})")
    print(f"EXIT={1 if bad else 0}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
