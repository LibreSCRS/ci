#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""check-workflows.py -- the workflows of a consuming repository, as data: every
gate is reached, every job is bounded, every step can run where it was placed,
and every reference to LibreSCRS/ci is the same commit.

Four rules, one entry point. They were three scripts (a wiring check, a
timeout check and a step-order check) byte-identical in eight repositories;
the fourth is new with the shared gates.

  wired     A gate nobody runs is not a gate. Every shipped script under
            ci/ tools/ packaging/ scripts/ Scripts/ e2e/ is REACHABLE by name
            from a workflow, an action.yml or the build system, transitively,
            or is listed in ci/gate-wiring-exceptions.txt with a reason. Every
            shipped self-test is in the set the self-test runner would run, and
            the runner runs nothing the repository does not ship. The shared
            gates are reached through `uses: LibreSCRS/ci/actions/gates@<sha>`
            and the repository's profile (profiles/<Repository>.txt here):
            every (gate, phase) the profile lists has a step calling the action
            with that phase, and every such step's phase has a gate. A call by
            profile is exactly the invocation-through-a-variable the name match
            cannot see, so it is resolved here rather than excused.
  timeouts  Every job in .github/workflows carries a job-level timeout-minutes.
            An unbounded job that hangs holds a runner for six hours and
            refuses to serve its log while it does. A composite action's steps
            carry no timeout of their own; the calling job's bound is theirs.
  order     A step cannot run where it was placed: a `working-directory:` or a
            local action before the checkout that provides it, a gate step in
            a job that checks nothing out, or a gate step in a job that does
            not run on push without a reason in ci/gate-job-exceptions.txt. A
            step calling LibreSCRS/ci/actions/gates is a gate step, and it
            reads the checkout its `root` input names (default: the
            workspace root).
  pins      Every `uses: LibreSCRS/ci/...@<ref>` and every checkout of
            LibreSCRS/ci in the repository names a full 40-hex commit, and all
            of them the SAME one. The workflow is the only place the pin lives:
            a ci/gates.ref file beside it would be a second source of truth
            that Dependabot never moves, so its presence fails too.

WHAT THIS DOES NOT CLAIM (written down rather than pretended away): that a
named script's exit code is honoured; that a `run:` body is interpreted beyond
a short list of directory-creating forms; that a step which deletes a tree
removes it from the provided set; anything about absolute paths. The wiring
match is textual: a script name left in a docstring of a script CI runs keeps
the wiring green after the step that really ran it is deleted.

The repository judged is --root, else REPO_ROOT, else $GITHUB_WORKSPACE, else
the git checkout around the current directory -- never the one this script
lives in. Its profile key is --repo-name, else the repository part of
$GITHUB_REPOSITORY, else the checkout's directory name.

Usage:
  check-workflows.py [options]                    all four rules
  check-workflows.py [options] wired
  check-workflows.py [options] timeouts [DIR]     DIR defaults to .github/workflows
  check-workflows.py [options] order [FILE...]    named files: shape not judged
  check-workflows.py [options] pins
Options: --root DIR  --repo-name NAME  --profiles DIR

Exit codes -- a consumer writes the condition as `rc = 0`, never "not 1":
  0  every rule judged and passed
  1  a rule found something; every finding names its file, job and step
  2  cannot judge: no repository, no workflows, fewer than
     ci/workflow-shape.txt declares, a job with no steps, unloadable YAML,
     PyYAML missing, a step calling actions/gates in a repository with no (or
     an empty) profile, no self-test runner while self-tests ship, or a runner
     that cannot say what it would run. With several rules, any finding (1)
     wins over a rule that could not judge (2); both are non-zero.
"""

import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - measured as exit 2, never as a pass
    sys.stderr.write(
        "FATAL: PyYAML is not importable -- this check reads the workflows as "
        "data and cannot judge without it\n")
    raise SystemExit(2)

HERE = Path(__file__).resolve().parent
RULES = ("wired", "timeouts", "order", "pins")

GATES_ACTION_RE = re.compile(r"^LibreSCRS/ci/actions/gates@(\S+)$", re.I)
CI_USES_LINE_RE = re.compile(
    r"""^\s*(?:-\s+)?uses:\s*['"]?(LibreSCRS/ci(?:/[^@\s'"]*)?)@([^\s'"#]*)""", re.I)
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class Cannot(Exception):
    """Raised for every "I cannot judge this" condition; becomes exit 2."""


def git(*args):
    try:
        out = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    except OSError:
        return None
    return out.stdout if out.returncode == 0 else None


def tracked(*pathspec):
    """Files git tracks under pathspec, or [] when this is not a checkout."""
    out = git("ls-files", "--", *pathspec)
    return [line for line in (out or "").splitlines() if line]


def repo_root(explicit):
    root = explicit or os.environ.get("REPO_ROOT") or os.environ.get("GITHUB_WORKSPACE")
    if not root:
        out = git("rev-parse", "--show-toplevel")
        root = out.strip() if out else ""
    if not root or not os.path.isdir(root):
        raise Cannot("no repository to judge -- set REPO_ROOT, pass --root, or run "
                     "inside a checkout")
    return os.path.abspath(root)


def load_run_gates():
    path = HERE / "run-gates.py"
    # A bytecode cache beside the shared scripts would land in the consumer's
    # view of this checkout; nothing here is imported often enough to need one.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("run_gates", path)
    if spec is None or not path.is_file():
        raise Cannot(f"no {path} to read profiles with")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --------------------------------------------------------------------------
# shared: workflows as data

def on_section(doc):
    """`on:` is a YAML 1.1 boolean, so safe_load gives the key as True."""
    for key in ("on", True, "True"):
        if isinstance(doc, dict) and key in doc:
            return doc[key]
    return None


def triggers(doc):
    section = on_section(doc)
    if section is None:
        return set()
    if isinstance(section, str):
        return {section}
    if isinstance(section, list):
        return {str(item) for item in section}
    if isinstance(section, dict):
        return {str(key) for key in section}
    return set()


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
    except OSError as exc:
        raise Cannot("cannot read %s: %s" % (path, exc))
    except yaml.YAMLError as exc:
        raise Cannot("%s is not loadable YAML: %s" % (path, exc))
    if not isinstance(doc, dict):
        raise Cannot("%s does not parse to a mapping" % path)
    return doc


def repo_workflows():
    return sorted(p for p in tracked(".github/workflows")
                  if p.endswith((".yml", ".yaml")))


def gates_steps(paths):
    """[(workflow, job, index, phase-or-None, step)] for every step calling
    LibreSCRS/ci/actions/gates. phase None means the `with.phase` is not a
    literal the profile could be matched against."""
    out = []
    for path in paths:
        doc = load(path)
        for job_name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            for index, step in enumerate(job.get("steps") or [], 1):
                if not isinstance(step, dict):
                    continue
                if not GATES_ACTION_RE.match(str(step.get("uses") or "")):
                    continue
                phase = (step.get("with") or {}).get("phase", "static")
                phase = str(phase).strip()
                if "${{" in phase:
                    phase = None
                out.append((os.path.basename(path), str(job_name), index, phase, step))
    return out


# --------------------------------------------------------------------------
# rule: wired

SCAN_PATHSPEC = ("ci/*", "tools/*", "packaging/*", "scripts/*", "Scripts/*", "e2e/*")
ROOT_PATHSPEC = (".github/workflows/*.yml", ".github/workflows/*.yaml",
                 ".github/actions/*/action.yml", ".github/actions/*/action.yaml",
                 "CMakeLists.txt", "*/CMakeLists.txt", "*.cmake", "*/*.cmake")
ALLOW = "ci/gate-wiring-exceptions.txt"
OWN_RUNNERS = ("ci/scripts/run-selftests.sh", "tools/run-selftests.sh")


def rule_wired(ctx):
    rc = 0
    # One pathspec, the same one the self-test runner picks its set with. It is
    # wider than the directories any single repository uses, on purpose -- a
    # gate that ships anywhere this project keeps scripts is in the candidate
    # set. `.selftest.` is a PARTITION, not an exclusion: a gate is reached by
    # being named, a self-test by falling inside the runner's pathspec.
    all_scripts = sorted(p for p in tracked(*SCAN_PATHSPEC) if p.endswith((".sh", ".py")))
    candidates = [p for p in all_scripts if ".selftest." not in p]
    shipped_selftests = [p for p in all_scripts if ".selftest." in p]

    workflows = repo_workflows()
    steps = gates_steps(workflows)
    if not candidates and not steps:
        print("FATAL: no candidate scripts found -- wrong root?", file=sys.stderr)
        return 2

    roots = sorted(set(tracked(*ROOT_PATHSPEC)))
    if not roots:
        print("FATAL: no workflow or CMake roots found -- cannot measure", file=sys.stderr)
        return 2

    # The match is anchored on a name boundary, never a bare substring: without
    # it `wired.sh` is "named" by every file mentioning `check-gates-wired.sh`.
    # Longest first, because an alternation takes the first name that fits.
    byname = {}
    for c in candidates:
        byname.setdefault(os.path.basename(c), []).append(c)
    names = sorted(byname, key=len, reverse=True)
    name_re = re.compile(r"(^|[^A-Za-z0-9_.-])(" + "|".join(map(re.escape, names)) + ")") \
        if names else None

    allowed = set()
    if os.path.isfile(ALLOW):
        with open(ALLOW, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                path = re.split(r"\s", line, maxsplit=1)[0]
                reason = line[len(path):].strip()
                if not reason:
                    print(f"FAIL: {ALLOW}: '{path}' carries no reason", file=sys.stderr)
                    rc = 1
                    continue
                if git("ls-files", "--error-unmatch", "--", path) is None:
                    print(f"FAIL: {ALLOW}: '{path}' is not a tracked file (stale entry)",
                          file=sys.stderr)
                    rc = 1
                    continue
                allowed.add(path)

    # An exception is a reachability ROOT, not a pardon: what it calls is
    # called too. Comment lines are stripped first, so a name written in a
    # comment does not count as wiring.
    reachable = set()
    frontier = list(roots) + sorted(allowed)
    while frontier and name_re is not None:
        nxt = []
        for f in frontier:
            if not os.path.isfile(f):
                continue
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if re.match(r"^\s*#", line):
                        continue
                    for m in name_re.finditer(line):
                        for c in byname.get(m.group(2), []):
                            if c == f or c in reachable:
                                continue
                            reachable.add(c)
                            nxt.append(c)
        frontier = nxt

    for c in candidates:
        if c in allowed:
            print(f"SKIP: {c} -- listed in {ALLOW}")
            continue
        if c not in reachable:
            print(f"FAIL: {c} is shipped but no workflow or build file names it",
                  file=sys.stderr)
            rc = 1

    # The shared gates: reached through the action and the profile.
    entries = []
    profile_file = None
    if steps or ctx["profile_exists"]:
        try:
            entries = ctx["run_gates"].load_profile(ctx["profiles"], ctx["repo"])
        except ctx["run_gates"].Cannot as exc:
            print(f"FATAL: {exc}", file=sys.stderr)
            return 2
        profile_file = f"profiles/{ctx['repo']}.txt"
    step_phases = {}
    for wf, job, index, phase, _ in steps:
        if phase is None:
            print(f"FAIL: {wf}::{job} step #{index} calls actions/gates with a phase "
                  f"that is not a literal -- the profile cannot be matched to it",
                  file=sys.stderr)
            rc = 1
            continue
        step_phases.setdefault(phase, []).append(f"{wf}::{job} step #{index}")
    profile_phases = {}
    for gate, phase in entries:
        profile_phases.setdefault(phase, []).append(gate)
        if phase not in step_phases:
            print(f"FAIL: {profile_file} lists {gate} in phase '{phase}', and no step "
                  f"calls LibreSCRS/ci/actions/gates with phase '{phase}'",
                  file=sys.stderr)
            rc = 1
    for phase, where in sorted(step_phases.items()):
        if phase not in profile_phases:
            print(f"FAIL: {', '.join(where)} calls actions/gates with phase '{phase}', "
                  f"which {profile_file} has no gate for -- a step that runs nothing",
                  file=sys.stderr)
            rc = 1
    for phase, gates in sorted(profile_phases.items()):
        if phase in step_phases:
            print(f"OK: phase '{phase}' ({', '.join(gates)}) is run by "
                  f"{', '.join(step_phases[phase])}")

    # R_SELFTEST: what the runner would execute == what the repository ships.
    # Reachability by name is the wrong instrument for a self-test -- the runner
    # selects by pathspec -- so the runner is asked, and both directions judged.
    runner = next((r for r in OWN_RUNNERS if os.path.isfile(r) and os.access(r, os.X_OK)),
                  None)
    if runner is not None:
        cmd, label = ["./" + runner, "--list"], runner
    elif any(g == "selftests" for g, _ in entries):
        cmd = ["bash", str(HERE / "run-consumer-selftests.sh"), "--root", ctx["root"], "--list"]
        label = "LibreSCRS/ci run-consumer-selftests.sh (profile gate 'selftests')"
    elif shipped_selftests:
        print("FATAL: no executable run-selftests.sh under ci/scripts/ or tools/, and no\n"
              "       'selftests' gate in this repository's profile -- a repository that\n"
              "       ships self-tests and has nothing to run them is the situation\n"
              "       this rule exists for, so this is not a pass.", file=sys.stderr)
        return 2
    else:
        cmd = None
    if cmd is not None:
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except OSError as exc:
            print(f"FATAL: {label} --list could not run: {exc}", file=sys.stderr)
            return 2
        if out.returncode != 0:
            print(f"FATAL: {label} --list failed -- cannot ask the runner what it "
                  f"would run", file=sys.stderr)
            return 2
        listed = sorted(set(line for line in out.stdout.splitlines() if line))
        if not listed and shipped_selftests:
            print(f"FATAL: {label} --list printed nothing while this repository ships\n"
                  f"       {len(shipped_selftests)} self-test(s). An empty answer is not "
                  f"an empty set.", file=sys.stderr)
            return 2
        for f in sorted(set(shipped_selftests) - set(listed)):
            print(f"FAIL: {f} is shipped but the runner would not run it", file=sys.stderr)
            print(f"      ({label} picks its set by pathspec; this file is outside it)",
                  file=sys.stderr)
            rc = 1
        for f in sorted(set(listed) - set(shipped_selftests)):
            print(f"FAIL: {label} would run {f}, which this repository does not track",
                  file=sys.stderr)
            rc = 1
        count = f"{len(listed)} self-tests, run by {label}"
    else:
        count = "no self-tests ship"

    if rc == 0:
        print(f"OK: every shipped gate is wired (or accounted for), and the runner's set "
              f"is the shipped set ({count})")
    return rc


# --------------------------------------------------------------------------
# rule: timeouts
#
# Deliberately not a YAML-library parse, and deliberately the same text rule
# it always was: a job-level timeout-minutes is four spaces in, a step-level
# one eight, and this project's workflows carry both. The rule reads what is
# written, not what a loader makes of it.

JOB_KEY = re.compile(r"^  [A-Za-z0-9_.-]+:[ \t]*$")


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


def rule_timeouts(ctx, args):
    directory = args[0] if args else ".github/workflows"
    files = sorted(str(p) for p in Path(directory).glob("*.yml")) + \
        sorted(str(p) for p in Path(directory).glob("*.yaml"))
    if not files:
        print(f"no workflow files under {directory} -- nothing to check, and that is "
              f"not a pass", file=sys.stderr)
        return 2
    rc, total, bounded = 0, 0, 0
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for job, ok in job_bounds(fh.read()):
                total += 1
                if ok:
                    bounded += 1
                else:
                    print(f"::error file={f}::job '{job}' has no timeout-minutes")
                    rc = 1
    print(f"jobs={total} bounded={bounded} unbounded={total - bounded}")
    return rc


# --------------------------------------------------------------------------
# rule: order
#
# Only what GitHub Actions declares as data: `working-directory:`, `uses:`,
# `if:`, `needs:`, `strategy.matrix`, `defaults.run.working-directory`. A
# relative path inside a shell command cannot be resolved without executing
# it, and guessing with a regular expression produces a false failure on the
# first `git clone` inside a `run:`. Threat model: an honest mistake in moving
# a step, and a job that does not run -- yes. Deliberate concealment -- no.

# A step is a "gate step" when its `run:` body names a path that looks like one
# of this project's own scripts, or when it calls the shared gates action.
# Shape, not existence: the committed fixture describes another repository's
# workflow, so a rule that asked the filesystem would judge a different set in
# each repository.
GATE_PATH_RE = re.compile(
    r"(?:^|[\s\"'(=|&;]|\./)"
    r"((?:ci|tools|packaging|scripts|Scripts|e2e)/[A-Za-z0-9._/-]+\.(?:sh|py))")

ALWAYS_IF = ("always()", "success()", "true", "!cancelled()")

MATRIX_IF_RE = re.compile(
    r"^matrix\.([A-Za-z_][A-Za-z0-9_-]*)"
    r"(?:\s*==\s*'([^']*)'|\s*==\s*\"([^\"]*)\")?$")

CLONE_DIR_RE = (
    re.compile(r"\bgit\s+clone\b[^\n;&|]*?\s(?!-)(\S+)\s*$", re.M),
    re.compile(r"\bgh\s+repo\s+clone\b[^\n;&|]*?\s(?!-)(\S+)\s*$", re.M),
    re.compile(r"\bmkdir\s+(?:-p\s+)?([^\n;&|]+)", re.M),
    re.compile(r"\btar\b[^\n;&|]*?\s-C\s+(\S+)", re.M),
)

JOB_EXCEPTIONS = "ci/gate-job-exceptions.txt"
SHAPE = "ci/workflow-shape.txt"


def clean_if(expr):
    text = str(expr).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()
    return text


def matrix_values(job, key):
    strategy = job.get("strategy") or {}
    matrix = strategy.get("matrix") or {}
    if not isinstance(matrix, dict):
        return []
    values = []
    axis = matrix.get(key)
    if isinstance(axis, list):
        values.extend(axis)
    elif axis is not None:
        values.append(axis)
    for leg in matrix.get("include") or []:
        if isinstance(leg, dict) and key in leg:
            values.append(leg[key])
    return values


def truthy(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip() not in ("", "false", "0")


def step_runs_on_push(job, step):
    if "if" not in step:
        return True, ""
    expr = clean_if(step["if"])
    if expr in ALWAYS_IF:
        return True, ""
    hit = MATRIX_IF_RE.match(expr)
    if hit:
        key = hit.group(1)
        wanted = hit.group(2) if hit.group(2) is not None else hit.group(3)
        values = matrix_values(job, key)
        if not values:
            return False, "matrix.%s is not in this job's matrix" % key
        if wanted is None:
            if any(truthy(value) for value in values):
                return True, ""
            return False, "no matrix leg gives %s a truthy value" % key
        if any(str(value) == wanted for value in values):
            return True, ""
        return False, "no matrix leg gives %s the value '%s'" % (key, wanted)
    return False, "if: %s" % expr


def job_runs_on_push(name, jobs, has_push, seen=None):
    if not has_push:
        return False, "the workflow has no push trigger"
    seen = seen or set()
    if name in seen:
        return False, "needs: forms a cycle through %s" % name
    seen = seen | {name}
    job = jobs.get(name)
    if job is None:
        return False, "needs: names a job that does not exist (%s)" % name
    if "if" in job:
        expr = clean_if(job["if"])
        if expr not in ALWAYS_IF:
            return False, "if: %s" % expr
    needs = job.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    for parent in needs:
        ok, why = job_runs_on_push(str(parent), jobs, has_push, seen)
        if not ok:
            return False, "needs: %s, which %s" % (parent, why)
    return True, ""


def provided_by(step):
    made = []
    uses = str(step.get("uses") or "")
    if re.match(r"^actions/checkout@", uses):
        with_ = step.get("with") or {}
        made.append(str(with_.get("path") or "."))
    body = step.get("run")
    if isinstance(body, str):
        for pattern in CLONE_DIR_RE:
            for hit in pattern.finditer(body):
                for token in str(hit.group(1)).split():
                    made.append(token)
    out = []
    for path in made:
        path = path.strip().strip("'\"")
        if not path or path.startswith("$") or os.path.isabs(path):
            continue
        out.append(os.path.normpath(path))
    return out


def reads_tree(step, defaults_wd):
    wd = step.get("working-directory")
    if wd is None and "run" in step:
        wd = defaults_wd
    if wd is not None:
        wd = str(wd).strip().strip("'\"")
        if wd and not wd.startswith("$") and not os.path.isabs(wd):
            return os.path.normpath(wd)
    uses = str(step.get("uses") or "")
    if uses.startswith("./"):
        return "."
    # The shared gates judge the checkout their `root` input names (the
    # workspace root by default).
    if GATES_ACTION_RE.match(uses):
        root = str((step.get("with") or {}).get("root") or ".").strip().strip("'\"")
        if root.startswith("$") or os.path.isabs(root):
            return None
        return os.path.normpath(root)
    return None


def covers(provided, wanted):
    if wanted in (".", ""):
        return "." in provided
    for have in provided:
        if have == ".":
            return True
        if wanted == have or wanted.startswith(have + "/"):
            return True
    return False


def defaults_wd_of(doc, job):
    for holder in (job, doc):
        run = ((holder.get("defaults") or {}).get("run") or {})
        if "working-directory" in run:
            return str(run["working-directory"])
    return None


def gate_scripts_in(step):
    if GATES_ACTION_RE.match(str(step.get("uses") or "")):
        return ["LibreSCRS/ci/actions/gates"]
    body = step.get("run")
    if not isinstance(body, str):
        return []
    return sorted({hit.group(1) for hit in GATE_PATH_RE.finditer(body)})


def step_label(index, step):
    name = step.get("name") or step.get("uses") or "run"
    return "#%d %s" % (index, str(name).splitlines()[0][:60])


def read_exceptions(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            text = line.rstrip("\n")
            if not text.strip() or text.lstrip().startswith("#"):
                continue
            parts = re.split(r"\s{2,}|\t", text.strip(), maxsplit=1)
            key = parts[0]
            reason = parts[1].strip() if len(parts) > 1 else ""
            bits = key.split(":")
            if len(bits) == 2:
                rows.append((lineno, bits[0], bits[1], None, reason))
            elif len(bits) == 3 and bits[2].isdigit():
                rows.append((lineno, bits[0], bits[1], int(bits[2]), reason))
            else:
                rows.append((lineno, key, None, None, reason))
    return rows


def read_shape(path):
    shape = {}
    if not os.path.exists(path):
        return shape
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            bits = line.split()
            if len(bits) == 2 and bits[1].isdigit():
                shape[bits[0]] = int(bits[1])
    return shape


def judge_order(paths, exceptions, shape, repo_mode):
    findings = []
    job_level_hits = {}
    used_rows = set()
    gate_steps_seen = 0
    jobs_total = 0

    for path in paths:
        doc = load(path)
        wf = os.path.basename(path)
        jobs = doc.get("jobs") or {}
        if not isinstance(jobs, dict) or not jobs:
            raise Cannot("%s declares no jobs" % path)
        has_push = "push" in triggers(doc)
        jobs_total += len(jobs)

        for job_name, job in jobs.items():
            if not isinstance(job, dict):
                raise Cannot("%s: job %s is not a mapping" % (path, job_name))
            steps = job.get("steps")
            if steps is None and "uses" in job:
                continue                    # a reusable-workflow call has no steps
            if not steps:
                raise Cannot("%s: job %s has no steps" % (path, job_name))
            job_ok, job_why = job_runs_on_push(str(job_name), jobs, has_push)
            defaults_wd = defaults_wd_of(doc, job)

            provided = set()
            for index, step in enumerate(steps, 1):
                if not isinstance(step, dict):
                    raise Cannot("%s: %s step %d is not a mapping"
                                 % (path, job_name, index))

                scripts = gate_scripts_in(step)

                # A step that runs one of this project's own scripts reads the
                # checkout by definition. "Some checkout, anywhere in this job"
                # is the weakest claim that still catches a gate step in a job
                # with no checkout at all -- the deploy job of a pages workflow.
                wanted = reads_tree(step, defaults_wd)
                if wanted is not None and not covers(provided, wanted):
                    findings.append(
                        "%s::%s step %s reads '%s' before anything provides it "
                        "(provided so far: %s)"
                        % (wf, job_name, step_label(index, step), wanted,
                           sorted(provided) or "nothing"))
                elif scripts and not provided:
                    findings.append(
                        "%s::%s step %s runs %s in a job that never checks "
                        "anything out"
                        % (wf, job_name, step_label(index, step),
                           ", ".join(scripts)))

                for made in provided_by(step):
                    provided.add(made)

                if not scripts:
                    continue
                gate_steps_seen += 1
                step_ok, step_why = step_runs_on_push(job, step)
                if job_ok and step_ok:
                    continue
                why = job_why if not job_ok else step_why
                row = None
                for candidate in exceptions:
                    _, c_wf, c_job, c_step, _ = candidate
                    if c_wf == wf and c_job == str(job_name) and \
                            (c_step is None or c_step == index):
                        row = candidate
                        break
                if row is not None and row[3] is None:
                    job_level_hits.setdefault(row[0], []).append(
                        (wf, str(job_name), index, step_label(index, step)))
                if row is None:
                    findings.append(
                        "%s::%s step %s runs %s but is not reached on push (%s) "
                        "and no reason is recorded"
                        % (wf, job_name, step_label(index, step),
                           ", ".join(scripts), why))
                    continue
                used_rows.add(row[0])
                if not row[4]:
                    findings.append(
                        "%s:%d excuses %s::%s with an empty reason"
                        % (JOB_EXCEPTIONS, row[0], wf, job_name))

    # A row that names a JOB excuses every gate step that job has -- and every
    # gate step that lands in it afterwards, which nobody decided. A row has to
    # name the step it excuses; the numbers go stale loudly, which is the point.
    for lineno, hits in sorted(job_level_hits.items()):
        wf, job_name = hits[0][0], hits[0][1]
        findings.append(
            "%s:%d excuses the whole of %s::%s -- name the step it excuses (%s), or a "
            "gate step moved into this job later is excused by a row written before "
            "it existed"
            % (JOB_EXCEPTIONS, lineno, wf, job_name,
               ", ".join("%s:%s:%d" % (wf, job_name, index) for _, _, index, _ in hits)))

    known_jobs = set()
    for path in paths:
        doc = load(path)
        for job_name in (doc.get("jobs") or {}):
            known_jobs.add((os.path.basename(path), str(job_name)))
    judged = {os.path.basename(p) for p in paths}
    for row in exceptions:
        lineno, c_wf, c_job, c_step, _ = row
        if lineno in used_rows:
            continue
        if not repo_mode and c_wf not in judged:
            continue
        if c_job is None:
            findings.append("%s:%d is not <workflow>:<job>[:<step>]  <reason>"
                            % (JOB_EXCEPTIONS, lineno))
        elif (c_wf, c_job) not in known_jobs:
            findings.append("%s:%d names %s::%s, which does not exist"
                            % (JOB_EXCEPTIONS, lineno, c_wf, c_job))
        else:
            findings.append(
                "%s:%d excuses %s::%s%s, which needs no excuse -- the row has "
                "outlived what it excused"
                % (JOB_EXCEPTIONS, lineno, c_wf, c_job,
                   "" if c_step is None else " step %d" % c_step))

    if repo_mode:
        want_wf = shape.get("min_workflows")
        want_jobs = shape.get("min_jobs")
        if want_wf is not None and len(paths) < want_wf:
            raise Cannot("found %d workflow(s), %s declares at least %d -- this is a "
                         "checkout that lost files, not a clean result"
                         % (len(paths), SHAPE, want_wf))
        if want_jobs is not None and jobs_total < want_jobs:
            raise Cannot("found %d job(s), %s declares at least %d"
                         % (jobs_total, SHAPE, want_jobs))
        if gate_steps_seen == 0 and tracked("ci/scripts"):
            raise Cannot("no gate step found in a repository that ships gate "
                         "scripts -- the rule measured nothing")

    return findings, gate_steps_seen, jobs_total


def rule_order(ctx, args):
    repo_mode = not args
    if repo_mode:
        paths = repo_workflows()
        if not paths:
            print("FATAL: no tracked workflows under .github/workflows -- wrong root?",
                  file=sys.stderr)
            return 2
    else:
        paths = list(args)
        for path in paths:
            if not os.path.exists(path):
                print("FATAL: %s does not exist" % path, file=sys.stderr)
                return 2
    try:
        findings, gates, jobs = judge_order(paths, read_exceptions(JOB_EXCEPTIONS),
                                            read_shape(SHAPE), repo_mode)
    except Cannot as exc:
        print("FATAL: %s" % exc, file=sys.stderr)
        return 2
    for finding in findings:
        print("FAIL: %s" % finding)
    print("workflow-step-order: %d workflow(s), %d job(s), %d gate step(s), "
          "%d finding(s)%s"
          % (len(paths), jobs, gates, len(findings),
             "" if repo_mode else " [named files only: shape not judged]"))
    return 1 if findings else 0


# --------------------------------------------------------------------------
# rule: pins

def rule_pins(ctx):
    rc = 0
    files = sorted(set(repo_workflows()) | set(tracked(".github/actions/*/action.yml",
                                                       ".github/actions/*/action.yaml")))
    refs = []                               # (ref, "file:line")
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                if re.match(r"^\s*#", line):
                    continue
                m = CI_USES_LINE_RE.match(line)
                if m:
                    refs.append((m.group(2), f"{f}:{lineno}"))
        # A checkout of LibreSCRS/ci is a pin too, and one without a ref
        # floats on the default branch.
        try:
            doc = load(f)
        except Cannot:
            continue
        for job_name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            for index, step in enumerate(job.get("steps") or [], 1):
                if not isinstance(step, dict):
                    continue
                if not str(step.get("uses") or "").startswith("actions/checkout@"):
                    continue
                with_ = step.get("with") or {}
                if str(with_.get("repository") or "").lower() != "librescrs/ci":
                    continue
                refs.append((str(with_.get("ref") or ""),
                             f"{f}::{job_name} step #{index} (checkout)"))
    for ref, where in refs:
        if not FULL_SHA_RE.match(ref):
            print(f"FAIL: {where} pins LibreSCRS/ci at '{ref or '(nothing)'}' -- a pin is "
                  f"a full 40-hex commit; a branch or tag moves under the workflow",
                  file=sys.stderr)
            rc = 1
    distinct = sorted({ref for ref, _ in refs if FULL_SHA_RE.match(ref)})
    if len(distinct) > 1:
        print(f"FAIL: LibreSCRS/ci is pinned at {len(distinct)} different commits -- one "
              f"repository runs one version of its gates:", file=sys.stderr)
        for d in distinct:
            print(f"      {d}: " + ", ".join(w for r, w in refs if r == d), file=sys.stderr)
        rc = 1
    if tracked("ci/gates.ref"):
        print("FAIL: ci/gates.ref is tracked -- the pin lives in the workflow's uses: "
              "line and nowhere else; a second copy is one Dependabot never moves",
              file=sys.stderr)
        rc = 1
    if rc == 0:
        if refs:
            print(f"OK: {len(refs)} reference(s) to LibreSCRS/ci, all at {distinct[0]}")
        else:
            print("OK: no reference to LibreSCRS/ci")
    return rc


# --------------------------------------------------------------------------

def main(argv):
    args = list(argv)
    opts = {"--root": None, "--repo-name": None, "--profiles": str(HERE.parent / "profiles")}
    while args and args[0] in opts:
        if len(args) < 2:
            print(f"FATAL: {args[0]} needs a value", file=sys.stderr)
            return 2
        opts[args[0]] = args[1]
        args = args[2:]
    rule = args.pop(0) if args else "all"
    if rule not in RULES + ("all",):
        print(f"FATAL: usage: check-workflows.py [--root D] [--repo-name N] "
              f"[--profiles D] [{'|'.join(RULES)}|all] [ARGS...]", file=sys.stderr)
        return 2
    if rule in ("all", "wired", "pins") and args:
        print(f"FATAL: '{rule}' takes no arguments", file=sys.stderr)
        return 2
    # Paths named on the command line are read from where the caller stands;
    # everything else from the repository root.
    args = [os.path.abspath(a) for a in args]
    try:
        root = repo_root(opts["--root"])
        os.chdir(root)
        rg = load_run_gates()
    except Cannot as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 2
    repo = (opts["--repo-name"]
            or os.environ.get("GITHUB_REPOSITORY", "").rpartition("/")[2]
            or os.path.basename(root))
    profiles = os.path.abspath(opts["--profiles"])
    ctx = {"root": root, "repo": repo, "profiles": profiles, "run_gates": rg,
           "profile_exists": rg.profile_path(profiles, repo).is_file()}

    def run(name):
        try:
            if name == "wired":
                return rule_wired(ctx)
            if name == "timeouts":
                return rule_timeouts(ctx, args)
            if name == "order":
                return rule_order(ctx, args)
            return rule_pins(ctx)
        except Cannot as exc:
            print(f"FATAL: {exc}", file=sys.stderr)
            return 2

    if rule != "all":
        return run(rule)
    results = {}
    for name in RULES:
        print(f"--- {name}", flush=True)
        sys.stdout.flush()
        results[name] = run(name)
        sys.stdout.flush()
        sys.stderr.flush()
    print("check-workflows: " + " ".join(f"{n}={results[n]}" for n in RULES))
    codes = set(results.values())
    if codes - {0, 2}:
        return 1
    return 2 if 2 in codes else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
