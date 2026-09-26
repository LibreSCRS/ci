#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""run-gates.py -- run the gates a consuming repository's profile lists.

The profile, not the workflow, says which shared gates a repository runs:
profiles/<Repository>.txt in this repository, one gate per line, each with the
phase it runs in. A workflow calls actions/gates once per phase -- `static` in
its lint job, a phase of its own naming after a build (`build`, `asan`, ...) --
and this runs every gate the profile puts in that phase, against the consumer's
checkout.

A profile that is missing, empty or unreadable is exit 2, never 0: a silent
green over a repository whose gate list was lost is the failure this layout has
to rule out. A phase the profile has no gate for is exit 2 too -- a step that
runs nothing is not a step that passed. check-workflows holds the other half:
every (gate, phase) of the profile is reached by some step, and every step's
phase has a gate.

PROFILE FORMAT
  # comment
  <gate> [<phase>]          phase defaults to `static`

  Gate and phase are [a-z0-9][a-z0-9-]*. A gate listed twice in one phase is
  an error. The gates and what each one needs are GATES below; the one
  `selftests` runs the consumer's own self-tests (the repository-specific ones
  that did not move here) through run-selftests.sh.

Usage:
  run-gates.py [--phase P] [--root DIR] [--repo NAME] [--build-dir D]
               [--build-log F] [--leg L] [--warning-leg W]
  run-gates.py --list [--phase P] [--repo NAME]   print what it would run
  run-gates.py --lint                             check every profile here

The repository judged is --root, else REPO_ROOT, else $GITHUB_WORKSPACE, else
the git checkout around the current directory. A job that checks the consumer
out into a subdirectory (beside the checkouts it builds against) names that
subdirectory with --root. Its name -- the profile key -- is
--repo, else the repository part of $GITHUB_REPOSITORY, else the checkout's
directory name.

Exit codes -- a consumer writes the condition as `rc = 0`, never "not 1":
  0  every gate of the phase ran and passed
  1  at least one gate failed (every gate still runs, so all findings show)
  2  cannot judge: no checkout, no profile or an empty one, a malformed or
     unknown entry, no gate in the requested phase, an input the phase needs
     is missing, bash older than 4, or a gate itself could not judge
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROFILES = HERE.parent / "profiles"
NAME = re.compile(r"[a-z0-9][a-z0-9-]*")
DEFAULT_PHASE = "static"


class Cannot(Exception):
    """Exit 2: this run cannot judge."""


# gate -> (interpreter, script, argv builder, inputs it needs)
# The builder gets the run context; the inputs are checked before anything
# runs. Interpreter "bash4" is a shell gate that needs bash 4 or later
# (mapfile, associative arrays); plain "bash" runs on the 3.2 macOS ships.
GATES = {
    "check-format-scope": ("bash4", "check-format-scope.sh", lambda c: [], ()),
    "check-skip-reasons": ("bash4", "check-skip-reasons.sh", lambda c: [], ()),
    "check-workflows": ("python", "check-workflows.py",
                        lambda c: ["--repo-name", c["repo"], "--profiles", c["profiles"]], ()),
    "canonical-types": ("python", "canonical-types.py", lambda c: ["--repo", c["repo"]], ()),
    "dup-scan": ("python", "dup-scan.py", lambda c: ["--repo", c["repo"]], ()),
    "selftests": ("bash4", "run-selftests.sh", lambda c: ["--root", c["root"]], ()),
    # deps.lock: format, reachability from upstream main, the diamond. After a
    # configure, the source tree CMake actually used must be the locked one --
    # the property, not the message the configure printed.
    "deps-lock": ("bash4", "bump-deps",
                  lambda c: ["check", "--root", c["root"], "--consumer", c["repo"]], ()),
    "deps-lock-build": ("bash4", "bump-deps",
                        lambda c: ["check", "--root", c["root"], "--consumer", c["repo"],
                                   "--no-remote", "--build-dir", c["build_dir"]],
                        ("build_dir",)),
    "test-manifest-gate": ("bash", "test-manifest-gate.sh",
                           lambda c: ["--check", c["build_dir"], c["leg"]],
                           ("build_dir", "leg")),
    "warning-gate": ("python", "warning-gate.py",
                     lambda c: ["--check", "--require-key"]
                     + (["--leg", c["warning_leg"]] if c["warning_leg"] else [])
                     + [c["build_log"], "--build-dir", c["build_dir"]],
                     ("build_dir", "build_log")),
}

INPUT_FLAG = {"build_dir": "build-dir", "build_log": "build-log", "leg": "leg"}


def parse_profile(path):
    """[(gate, phase)] in file order. Raises Cannot on anything malformed."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise Cannot(f"cannot read profile {path}: {exc}")
    entries = []
    seen = set()
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        bits = line.split()
        if len(bits) > 2:
            raise Cannot(f"{path}:{lineno}: '{line}' is not <gate> [<phase>]")
        gate = bits[0]
        phase = bits[1] if len(bits) == 2 else DEFAULT_PHASE
        for word in (gate, phase):
            if not NAME.fullmatch(word):
                raise Cannot(f"{path}:{lineno}: '{word}' is not a name ([a-z0-9-])")
        if gate not in GATES:
            raise Cannot(f"{path}:{lineno}: '{gate}' is not a gate this repository "
                         f"runs (known: {', '.join(sorted(GATES))})")
        if (gate, phase) in seen:
            raise Cannot(f"{path}:{lineno}: '{gate}' is listed twice in phase '{phase}'")
        seen.add((gate, phase))
        entries.append((gate, phase))
    if not entries:
        raise Cannot(f"profile {path} lists no gate -- an empty profile judges nothing")
    return entries


def profile_path(profiles, repo):
    return Path(profiles) / f"{repo}.txt"


def load_profile(profiles, repo):
    path = profile_path(profiles, repo)
    if not path.is_file():
        raise Cannot(f"no profile for '{repo}' at {path} -- a repository with no "
                     f"profile is not judged by an empty one")
    return parse_profile(path)


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


def repo_name(explicit, root):
    return (explicit or os.environ.get("GITHUB_REPOSITORY", "").rpartition("/")[2]
            or os.path.basename(root))


def bash_is_new_enough():
    try:
        out = subprocess.run(["bash", "-c", "echo ${BASH_VERSINFO[0]}"],
                             capture_output=True, text=True, check=False)
    except OSError:
        return False
    return out.returncode == 0 and out.stdout.strip().isdigit() \
        and int(out.stdout.strip()) >= 4


def lint(profiles):
    """Every profile here parses, and names only known gates."""
    paths = sorted(Path(profiles).glob("*.txt"))
    if not paths:
        print(f"FATAL: no profiles under {profiles}", file=sys.stderr)
        return 2
    bad = 0
    for path in paths:
        try:
            entries = parse_profile(path)
        except Cannot as exc:
            print(f"FAIL: {exc}")
            bad += 1
            continue
        phases = sorted({p for _, p in entries})
        print(f"ok    {path.name}: {len(entries)} gate(s) in {', '.join(phases)}")
    return 1 if bad else 0


def main(argv):
    ap = argparse.ArgumentParser(description="run the gates a profile lists")
    ap.add_argument("--phase", default=DEFAULT_PHASE)
    ap.add_argument("--root", default=None, help="the consumer checkout")
    ap.add_argument("--repo", default=None, help="profile key (repository name)")
    ap.add_argument("--profiles", default=str(PROFILES))
    ap.add_argument("--build-dir", default="")
    ap.add_argument("--build-log", default="")
    ap.add_argument("--leg", default="", help="test-manifest leg")
    ap.add_argument("--warning-leg", default="", help="warning-baseline leg")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--lint", action="store_true")
    args = ap.parse_args(argv)

    if args.lint:
        return lint(args.profiles)

    try:
        if not NAME.fullmatch(args.phase):
            raise Cannot(f"phase '{args.phase}' is not a name ([a-z0-9-])")
        root = repo_root(args.root)
        repo = repo_name(args.repo, root)
        entries = load_profile(args.profiles, repo)
        gates = [g for g, p in entries if p == args.phase]
        if not gates:
            have = sorted({p for _, p in entries})
            raise Cannot(f"profile '{repo}' has no gate in phase '{args.phase}' "
                         f"(its phases: {', '.join(have)}) -- a step that runs "
                         f"nothing has not passed")
        ctx = {"root": root, "repo": repo, "profiles": str(Path(args.profiles).resolve()),
               "build_dir": args.build_dir, "build_log": args.build_log, "leg": args.leg,
               "warning_leg": args.warning_leg}
        missing = sorted({INPUT_FLAG[i] for g in gates for i in GATES[g][3] if not ctx[i]})
        if missing:
            raise Cannot(f"phase '{args.phase}' runs {', '.join(gates)}, which need "
                         f"{', '.join('--' + m for m in missing)}")
        if any(GATES[g][0] == "bash4" for g in gates) and not bash_is_new_enough():
            raise Cannot("the bash on PATH is older than 4 -- these gates need 4 or "
                         "later (on macOS: brew install bash)")
    except Cannot as exc:
        print(f"run-gates: FATAL: {exc}", file=sys.stderr)
        return 2

    if args.list:
        for g in gates:
            print(g)
        return 0

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
    print(f"run-gates: {repo} phase {args.phase}: {len(results)} gate(s), "
          f"{len(results) - failed - unjudged} passed, {failed} failed, "
          f"{unjudged} could not judge")
    if failed:
        return 1
    return 2 if unjudged else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
