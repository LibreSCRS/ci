#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""gates-inventory.py -- which repository runs which gate, in which workflow,
job and event: read from the workflows as data, not from anyone's notes.

One row per (repository, gate, script, workflow, job). A gate is found two ways:

  * inline -- a `run:` body names one of the repository's scripts
    (`ci/scripts/X.sh`, `tools/X.py`, `packaging/...`, also under a checkout
    subdirectory such as `_src/ci/scripts/X.sh`);
  * through LibreSCRS/ci -- a step `uses: LibreSCRS/ci/actions/<name>@<sha>`.
    For actions/gates the gates are the consumer's profile entries for the
    step's `phase` (profiles/<Repository>.txt); for any other action they are
    the scripts its action.yml names.

The gate column is the script's name without directory and extension
(`check-format-scope`, `warning-gate`, `check-format-scope.selftest`), which is
what stays the same when a script moves from a consumer to this repository --
so a BEFORE list (inline) and an AFTER list (through the action) can be
compared row for row with --diff.

Columns (TSV, header first):
  repo  gate  script  workflow  job  events  condition  via

  events     the workflow's triggers, sorted; `push:tags` when push fires only
             on tags
  condition  the job's and the step's `if:`, joined by `&&`, or `-`
  via        `inline`, or `action:<name>[:<phase>]`

Usage:
  gates-inventory.py --workspace DIR [--rev REV] [--ci-root DIR] [--repos A,B]
  gates-inventory.py --diff BEFORE.tsv AFTER.tsv

--rev reads each repository's workflows at that revision (`git show`), not the
working tree, so a list can be taken of a branch nobody has checked out.
--ci-root is the LibreSCRS/ci checkout whose profiles and actions resolve the
`uses:` steps (default: the one this script is in).

--diff prints the rows present on one side only, keyed by (repo, gate,
workflow, job): `-` for a gate that stopped running there, `+` for one that
started. Exit 1 when any row differs, so an accepted difference is one someone
read.

Exit: 0 listed (or no difference), 1 a difference, 2 cannot judge (no
workflows in a repository, unloadable YAML, PyYAML missing, a `uses:` step
whose action or profile cannot be resolved).
"""
import argparse
import csv
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - exit 2, never a pass
    sys.stderr.write("FATAL: PyYAML is not importable -- cannot read workflows\n")
    raise SystemExit(2)

HERE = Path(__file__).resolve().parent
REPOS = ["LibreMiddleware", "LibreAgent", "LibreLinux", "LibreCelik", "LibreKDE",
         "LibreDarwin", "LibreMac", "LibreSCRS.github.io"]
COLUMNS = ["repo", "gate", "script", "workflow", "job", "events", "condition", "via"]

SCRIPT_RE = re.compile(
    r"(?<![\w.$/-])(?:\./)?((?:[\w.-]+/)*?(?:ci|tools|packaging|scripts|Scripts|e2e)"
    r"/(?:[\w.-]+/)*[\w.-]+\.(?:sh|py))(?![\w.-])")
CI_USES_RE = re.compile(r"^LibreSCRS/ci/actions/([\w.-]+)@(\S+)$", re.I)
ACTION_SCRIPT_RE = re.compile(r"\$\{?GITHUB_ACTION_PATH\}?/\.\./\.\./scripts/([\w.-]+)")


class Cannot(Exception):
    pass


def load_run_gates(ci_root):
    path = Path(ci_root) / "scripts" / "run-gates.py"
    # A bytecode cache beside the shared scripts would land in the consumer's
    # view of this checkout; nothing here is imported often enough to need one.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("run_gates", path)
    if spec is None or not path.is_file():
        raise Cannot(f"no {path} to read profiles with")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def gate_id(script):
    base = os.path.basename(script)
    for ext in (".sh", ".py"):
        if base.endswith(ext):
            return base[: -len(ext)]
    return base


def git(repo, *args):
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                         text=True, check=False)
    if out.returncode != 0:
        raise Cannot(f"git -C {repo} {' '.join(args)}: {out.stderr.strip()}")
    return out.stdout


def workflow_files(repo, rev):
    if rev:
        names = git(repo, "ls-tree", "-r", "--name-only", rev, "--", ".github/workflows")
    else:
        names = git(repo, "ls-files", "--", ".github/workflows")
    return sorted(n for n in names.splitlines() if n.endswith((".yml", ".yaml")))


def read(repo, rev, path):
    return git(repo, "show", f"{rev}:{path}") if rev else (Path(repo) / path).read_text()


def on_section(doc):
    for key in ("on", True, "True"):
        if isinstance(doc, dict) and key in doc:
            return doc[key]
    return None


def events_of(doc):
    section = on_section(doc)
    if isinstance(section, str):
        return [section]
    if isinstance(section, list):
        return sorted(str(s) for s in section)
    if isinstance(section, dict):
        out = []
        for key, val in section.items():
            key = str(key)
            if key == "push" and isinstance(val, dict) and "tags" in val \
                    and "branches" not in val:
                out.append("push:tags")
            else:
                out.append(key)
        return sorted(out)
    return []


def cond(*exprs):
    parts = []
    for e in exprs:
        if e is None:
            continue
        text = str(e).strip()
        if text.startswith("${{") and text.endswith("}}"):
            text = text[3:-2].strip()
        parts.append(" ".join(text.split()))
    return " && ".join(parts) if parts else "-"


class Resolver:
    """Turns a `uses: LibreSCRS/ci/actions/...` step into gate rows."""

    def __init__(self, ci_root):
        self.ci_root = Path(ci_root)
        self._rg = None

    def run_gates(self):
        if self._rg is None:
            self._rg = load_run_gates(self.ci_root)
        return self._rg

    def gates_for(self, repo, action, step):
        if action == "gates":
            rg = self.run_gates()
            phase = str((step.get("with") or {}).get("phase") or rg.DEFAULT_PHASE)
            try:
                entries = rg.load_profile(self.ci_root / "profiles", repo)
            except rg.Cannot as exc:
                raise Cannot(str(exc))
            out = []
            for gate, p in entries:
                if p != phase:
                    continue
                script = rg.GATES[gate][1]
                out.append((gate, f"LibreSCRS/ci:scripts/{script}", f"action:gates:{phase}"))
            return out
        yml = self.ci_root / "actions" / action / "action.yml"
        if not yml.is_file():
            raise Cannot(f"{repo}: uses LibreSCRS/ci/actions/{action}, which {yml} "
                         f"does not provide")
        text = yml.read_text()
        scripts = sorted(set(ACTION_SCRIPT_RE.findall(text)))
        return [(gate_id(s), f"LibreSCRS/ci:scripts/{s}", f"action:{action}")
                for s in scripts]


def inventory(workspace, repos, rev, resolver):
    rows = set()
    for repo in repos:
        path = Path(workspace) / repo
        if not path.is_dir():
            raise Cannot(f"no checkout at {path}")
        files = workflow_files(path, rev)
        if not files:
            raise Cannot(f"{repo}: no workflows under .github/workflows")
        for wf in files:
            try:
                doc = yaml.safe_load(read(path, rev, wf))
            except yaml.YAMLError as exc:
                raise Cannot(f"{repo}/{wf}: not loadable YAML: {exc}")
            if not isinstance(doc, dict):
                raise Cannot(f"{repo}/{wf}: not a mapping")
            events = ",".join(events_of(doc)) or "-"
            for job_name, job in (doc.get("jobs") or {}).items():
                if not isinstance(job, dict):
                    continue
                for step in job.get("steps") or []:
                    if not isinstance(step, dict):
                        continue
                    where = (repo, os.path.basename(wf), str(job_name), events,
                             cond(job.get("if"), step.get("if")))
                    body = step.get("run")
                    if isinstance(body, str):
                        for line in body.splitlines():
                            if line.lstrip().startswith("#"):
                                continue
                            for m in SCRIPT_RE.finditer(line):
                                script = m.group(1)
                                rows.add((repo, gate_id(script), script, *where[1:], "inline"))
                    uses = str(step.get("uses") or "")
                    hit = CI_USES_RE.match(uses)
                    if hit:
                        for gate, script, via in resolver.gates_for(repo, hit.group(1), step):
                            rows.add((repo, gate, script, *where[1:], via))
    return sorted(rows)


def write(rows, out):
    w = csv.writer(out, delimiter="\t", lineterminator="\n")
    w.writerow(COLUMNS)
    for r in rows:
        w.writerow(r)


def load(path):
    with open(path, encoding="utf-8") as fh:
        rd = csv.reader(fh, delimiter="\t")
        head = next(rd, None)
        if head != COLUMNS:
            raise Cannot(f"{path}: header is not {' '.join(COLUMNS)}")
        return [tuple(r) for r in rd if r]


def diff(before, after):
    def key(r):
        return (r[0], r[1], r[3], r[4])
    b = {key(r): r for r in load(before)}
    a = {key(r): r for r in load(after)}
    changed = 0
    for k in sorted(set(b) | set(a)):
        if k in b and k not in a:
            print("-\t" + "\t".join(b[k]))
            changed += 1
        elif k in a and k not in b:
            print("+\t" + "\t".join(a[k]))
            changed += 1
    print(f"gates-inventory: {len(b)} before, {len(a)} after, {changed} row(s) differ",
          file=sys.stderr)
    return 1 if changed else 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--workspace")
    ap.add_argument("--repos", default=",".join(REPOS))
    ap.add_argument("--rev", default="")
    ap.add_argument("--ci-root", default=str(HERE.parent))
    ap.add_argument("--diff", nargs=2, metavar=("BEFORE", "AFTER"))
    args = ap.parse_args(argv)
    try:
        if args.diff:
            return diff(*args.diff)
        if not args.workspace:
            raise Cannot("--workspace is required")
        rows = inventory(args.workspace, [r for r in args.repos.split(",") if r],
                         args.rev, Resolver(args.ci_root))
    except Cannot as exc:
        print(f"gates-inventory: FATAL: {exc}", file=sys.stderr)
        return 2
    write(rows, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
