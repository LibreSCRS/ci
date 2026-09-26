#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""check-workflows.py -- two rules over a consuming repository's workflows.

  timeouts  Every job in .github/workflows carries a job-level
            timeout-minutes. An unbounded job that hangs holds a runner for six
            hours and refuses to serve its log while it does. A composite
            action's steps carry no timeout of their own; the calling job's
            bound is theirs.
  pins      Every `uses: LibreSCRS/ci/...@<ref>` and every checkout of
            LibreSCRS/ci in the repository names a full 40-hex commit, and all
            of them the SAME one: one repository runs one version of its gates.
            The workflow is the only place the pin lives; a ci/gates.ref file
            beside it would be a second copy Dependabot never moves, so its
            presence fails too.

The repository judged is --root, else REPO_ROOT, else $GITHUB_WORKSPACE, else
the git checkout around the current directory -- never the one this script
lives in.

Usage:
  check-workflows.py [--root DIR]                  both rules
  check-workflows.py [--root DIR] timeouts [DIR]   DIR defaults to .github/workflows
  check-workflows.py [--root DIR] pins

Exit codes -- a consumer writes the condition as `rc = 0`, never "not 1":
  0  every rule judged and passed
  1  a rule found something
  2  cannot judge: no repository, no workflow files, PyYAML missing. With both
     rules, a finding (1) wins over a rule that could not judge (2).
"""

import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # measured as exit 2, never as a pass
    sys.stderr.write("FATAL: PyYAML is not importable -- cannot judge\n")
    raise SystemExit(2)

RULES = ("timeouts", "pins")
CI_USES_LINE_RE = re.compile(
    r"""^\s*(?:-\s+)?uses:\s*['"]?(LibreSCRS/ci(?:/[^@\s'"]*)?)@([^\s'"#]*)""", re.I)
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# Deliberately a text rule: a job-level timeout-minutes is four spaces in, a
# step-level one eight, and this project's workflows carry both.
JOB_KEY = re.compile(r"^  [A-Za-z0-9_.-]+:[ \t]*$")


class Cannot(Exception):
    """Becomes exit 2."""


def tracked(*pathspec):
    out = subprocess.run(["git", "ls-files", "--", *pathspec],
                         capture_output=True, text=True, check=False)
    return [line for line in out.stdout.splitlines() if line] if out.returncode == 0 else []


def repo_root(explicit):
    root = explicit or os.environ.get("REPO_ROOT") or os.environ.get("GITHUB_WORKSPACE")
    if not root:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=False)
        root = out.stdout.strip() if out.returncode == 0 else ""
    if not root or not os.path.isdir(root):
        raise Cannot("no repository to judge -- set REPO_ROOT, pass --root, or run "
                     "inside a checkout")
    return os.path.abspath(root)


def job_bounds(text):
    """[(job, bounded)] in file order."""
    order, bound = [], {}
    in_jobs, cur = False, ""
    for line in text.splitlines():
        if re.match(r"^jobs:[ \t]*$", line):
            in_jobs = True
            continue
        if in_jobs and re.match(r"^[^ \t#]", line):
            in_jobs = False
        if in_jobs and JOB_KEY.match(line):
            cur = line.split(":", 1)[0].strip()
            bound[cur] = False
            order.append(cur)
            continue
        if in_jobs and line.startswith("    timeout-minutes:") and cur:
            bound[cur] = True
    return [(j, bound[j]) for j in order]


def rule_timeouts(args):
    directory = args[0] if args else ".github/workflows"
    files = sorted(str(p) for p in Path(directory).glob("*.yml")) + \
        sorted(str(p) for p in Path(directory).glob("*.yaml"))
    if not files:
        raise Cannot(f"no workflow files under {directory} -- nothing to check is not a pass")
    rc, total, bounded = 0, 0, 0
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for job, ok in job_bounds(fh.read()):
                total += 1
                bounded += ok
                if not ok:
                    print(f"::error file={f}::job '{job}' has no timeout-minutes")
                    rc = 1
    print(f"jobs={total} bounded={bounded} unbounded={total - bounded}")
    return rc


def ci_refs(path):
    """[(ref, where)] for every reference to LibreSCRS/ci in one file."""
    refs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        raise Cannot(f"cannot read {path}: {exc.strerror}")
    for lineno, line in enumerate(text.splitlines(), 1):
        m = None if re.match(r"^\s*#", line) else CI_USES_LINE_RE.match(line)
        if m:
            refs.append((m.group(2), f"{path}:{lineno}"))
    # A checkout of LibreSCRS/ci is a pin too; one without a ref floats.
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise Cannot(f"{path} is not loadable YAML: {exc}")
    for job_name, job in ((doc or {}).get("jobs") or {}).items() if isinstance(doc, dict) else ():
        for index, step in enumerate((job or {}).get("steps") or [], 1):
            if not isinstance(step, dict) or \
                    not str(step.get("uses") or "").startswith("actions/checkout@"):
                continue
            with_ = step.get("with") or {}
            if str(with_.get("repository") or "").lower() == "librescrs/ci":
                refs.append((str(with_.get("ref") or ""),
                             f"{path}::{job_name} step #{index} (checkout)"))
    return refs


def rule_pins():
    files = sorted(set(tracked(".github/workflows/*.yml", ".github/workflows/*.yaml",
                               ".github/actions/*/action.yml",
                               ".github/actions/*/action.yaml")))
    refs = [r for f in files for r in ci_refs(f)]
    rc = 0
    for ref, where in refs:
        if not FULL_SHA_RE.match(ref):
            print(f"FAIL: {where} pins LibreSCRS/ci at '{ref or '(nothing)'}' -- a pin is "
                  f"a full 40-hex commit; a branch or tag moves under the workflow")
            rc = 1
    distinct = sorted({ref for ref, _ in refs if FULL_SHA_RE.match(ref)})
    if len(distinct) > 1:
        print(f"FAIL: LibreSCRS/ci is pinned at {len(distinct)} different commits:")
        for d in distinct:
            print(f"      {d}: " + ", ".join(w for r, w in refs if r == d))
        rc = 1
    if tracked("ci/gates.ref"):
        print("FAIL: ci/gates.ref is tracked -- the pin lives in the workflow's uses: "
              "line and nowhere else")
        rc = 1
    if rc == 0:
        print(f"OK: {len(refs)} reference(s) to LibreSCRS/ci, all at {distinct[0]}"
              if refs else "OK: no reference to LibreSCRS/ci")
    return rc


def main(argv):
    args = list(argv)
    explicit = None
    if args[:1] == ["--root"]:
        if len(args) < 2:
            print("FATAL: --root needs a value", file=sys.stderr)
            return 2
        explicit, args = args[1], args[2:]
    rule = args.pop(0) if args else "all"
    if rule not in RULES + ("all",) or (rule != "timeouts" and args):
        print("FATAL: usage: check-workflows.py [--root D] [timeouts [DIR] | pins]",
              file=sys.stderr)
        return 2
    args = [os.path.abspath(a) for a in args]   # read from where the caller stands
    results = {}
    for name in (RULES if rule == "all" else (rule,)):
        try:
            os.chdir(repo_root(explicit))
            results[name] = rule_timeouts(args) if name == "timeouts" else rule_pins()
        except Cannot as exc:
            print(f"FATAL: {exc}", file=sys.stderr)
            results[name] = 2
    if rule == "all":
        print("check-workflows: " + " ".join(f"{n}={results[n]}" for n in RULES))
    codes = set(results.values())
    return 1 if codes - {0, 2} else (2 if 2 in codes else 0)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
