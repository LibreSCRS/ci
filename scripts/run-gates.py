#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""run-gates.py -- run the shared gates a workflow step names, against the
consumer's checkout.

The step says which gates it runs (`gates: "check-version deps-lock"` on
actions/gates); what is run is read where it runs. An empty list or a name
this file does not know is exit 2, never 0: a step that runs nothing has not
passed.

Usage:
  run-gates.py --gates "G1 G2 ..." [--root DIR] [--repo NAME] [--build-dir D]
               [--build-log F] [--warning-leg W] [--floor FILE]

The repository judged is --root, else REPO_ROOT, else $GITHUB_WORKSPACE, else
the git checkout around the current directory. Its name (deps-lock asks for
it) is --repo, else the repository part of $GITHUB_REPOSITORY, else the
checkout's directory name.

Exit codes -- a consumer writes the condition as `rc = 0`, never "not 1":
  0  every named gate ran and passed
  1  at least one gate failed (every gate still runs, so all findings show)
  2  cannot judge: no checkout, no gate named, an unknown gate, an input a
     named gate needs is missing, bash older than 4, or a gate itself could
     not judge
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


class Cannot(Exception):
    """Exit 2: this run cannot judge."""


# gate -> (interpreter, script, argv builder, inputs it needs). Interpreter
# "bash4" needs bash 4 or later (mapfile, associative arrays).
GATES = {
    "check-skip-reasons": ("bash4", "check-skip-reasons.sh", lambda c: [], ()),
    "check-workflows": ("python", "check-workflows.py", lambda c: [], ()),
    "selftests": ("bash4", "run-selftests.sh", lambda c: ["--root", c["root"]], ()),
    # Everything in the tree that states a version states VERSION's, and the
    # CHANGELOG has the section the release is heading for.
    "check-version": ("bash4", "check-version.sh", lambda c: ["--min", "1", "--verbose"], ()),
    # A tree with no CMake build (the macOS host) asks only the lockstep arm.
    "check-version-lockstep": ("bash4", "check-version.sh", lambda c: ["--arms", "lockstep"], ()),
    # deps.lock: format, reachability from upstream main, the diamond. After a
    # configure, the source tree CMake actually used must be the locked one.
    "deps-lock": ("bash4", "bump-deps",
                  lambda c: ["check", "--root", c["root"], "--consumer", c["repo"]], ()),
    "deps-lock-build": ("bash4", "bump-deps",
                        lambda c: ["check", "--root", c["root"], "--consumer", c["repo"],
                                   "--no-remote", "--build-dir", c["build_dir"]],
                        ("build_dir",)),
    "test-floor": ("python", "test-floor.py",
                   lambda c: (["--floor", c["floor"]] if c["floor"] else []) + [c["build_dir"]],
                   ("build_dir",)),
    "warning-gate": ("python", "warning-gate.py",
                     lambda c: ["--check", "--require-key"]
                     + (["--leg", c["warning_leg"]] if c["warning_leg"] else [])
                     + [c["build_log"], "--build-dir", c["build_dir"]],
                     ("build_dir", "build_log")),
}

INPUT_FLAG = {"build_dir": "build-dir", "build_log": "build-log"}


def repo_root(explicit=None):
    root = explicit or os.environ.get("REPO_ROOT") or os.environ.get("GITHUB_WORKSPACE")
    if not root:
        try:
            out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                                 capture_output=True, text=True, check=False)
        except OSError:
            out = None
        root = out.stdout.strip() if out is not None and out.returncode == 0 else ""
    if not root or not os.path.isdir(root):
        raise Cannot("no repository to judge -- set REPO_ROOT, or run inside a checkout")
    return os.path.abspath(root)


def bash_is_new_enough():
    try:
        out = subprocess.run(["bash", "-c", "echo ${BASH_VERSINFO[0]}"],
                             capture_output=True, text=True, check=False)
    except OSError:
        return False
    return out.returncode == 0 and out.stdout.strip().isdigit() \
        and int(out.stdout.strip()) >= 4


def main(argv):
    ap = argparse.ArgumentParser(description="run the shared gates a step names")
    ap.add_argument("--gates", default="")
    ap.add_argument("--root", default=None, help="the consumer checkout")
    ap.add_argument("--repo", default=None, help="the consumer's repository name")
    ap.add_argument("--build-dir", default="")
    ap.add_argument("--build-log", default="")
    ap.add_argument("--warning-leg", default="", help="warning-baseline leg")
    ap.add_argument("--floor", default="", help="test-floor file (default ci/test-floor.txt)")
    args = ap.parse_args(argv)

    try:
        gates = args.gates.split()
        if not gates:
            raise Cannot("no gate named -- a step that runs nothing has not passed")
        unknown = [g for g in gates if g not in GATES]
        if unknown:
            raise Cannot(f"unknown gate(s): {', '.join(unknown)} "
                         f"(known: {', '.join(sorted(GATES))})")
        if len(set(gates)) != len(gates):
            raise Cannot(f"a gate is named twice in '{args.gates}'")
        root = repo_root(args.root)
        repo = (args.repo or os.environ.get("GITHUB_REPOSITORY", "").rpartition("/")[2]
                or os.path.basename(root))
        ctx = {"root": root, "repo": repo, "build_dir": args.build_dir,
               "build_log": args.build_log, "warning_leg": args.warning_leg,
               "floor": args.floor}
        missing = sorted({INPUT_FLAG[i] for g in gates for i in GATES[g][3] if not ctx[i]})
        if missing:
            raise Cannot(f"{', '.join(gates)} need {', '.join('--' + m for m in missing)}")
        if any(GATES[g][0] == "bash4" for g in gates) and not bash_is_new_enough():
            raise Cannot("the bash on PATH is older than 4 -- these gates need 4 or "
                         "later (on macOS: brew install bash)")
    except Cannot as exc:
        print(f"run-gates: FATAL: {exc}", file=sys.stderr)
        return 2

    env = dict(os.environ, REPO_ROOT=root)
    if args.build_dir:
        # How the consumer's self-tests that need a built tree are told where.
        env["BUILD_DIR"] = args.build_dir
    results = []
    grouped = os.environ.get("GITHUB_ACTIONS") == "true"
    for gate in gates:
        interp, script, argv_of, _ = GATES[gate]
        cmd = ([sys.executable] if interp == "python" else ["bash"]) \
            + [str(HERE / script)] + argv_of(ctx)
        print(f"::group::{gate}" if grouped else f"--- {gate}", flush=True)
        rc = subprocess.run(cmd, cwd=root, env=env, check=False).returncode
        if grouped:
            print("::endgroup::", flush=True)
        verdict = {0: "passed", 2: "cannot judge"}.get(rc, "FAILED")
        results.append((gate, rc, verdict))
        if rc != 0:
            print(f"::error::{gate} {verdict} (exit {rc})" if grouped
                  else f"{gate}: {verdict} (exit {rc})", flush=True)

    for gate, rc, verdict in results:
        print(f"  {verdict:<13} {gate} (exit {rc})")
    failed = sum(1 for _, rc, _ in results if rc not in (0, 2))
    unjudged = sum(1 for _, rc, _ in results if rc == 2)
    print(f"run-gates: {repo}: {len(results)} gate(s), "
          f"{len(results) - failed - unjudged} passed, {failed} failed, "
          f"{unjudged} could not judge")
    if failed:
        return 1
    return 2 if unjudged else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
