#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""test-floor.py -- every test binary a build registers with CTest carries at
least the number of tests the consumer's floor file names for it.

A suite that quietly stops being registered reads as success: ctest runs
what it was given, and zero of something is a pass. The floor is the
smallest thing that makes that loud without a list of every test name to
regenerate on each commit: one line per binary, a count it must reach.

Counted from `ctest --show-only=json-v1`, never by running anything: each
registered test's command names its binary (gtest_discover_tests registers
one test per case, all with the same binary; a plain add_test registers
one), so the count is the number of tests CTest would run from that binary.

FLOOR FILE (default ci/test-floor.txt, relative to the consumer root)
  # comment
  <binary> <n>        basename of the executable; n >= 1

Findings (exit 1): a listed binary the build does not register at all; a
binary with fewer tests than its floor. Cannot judge (exit 2): no
repository, no floor file or an empty one, a malformed line, a binary
listed twice, a build dir that is not one, ctest failing, no test at all,
or a test registered as <name>_NOT_BUILT (a build that did not happen).
A binary the build has and the file does not name is printed, not judged:
new tests are welcome, and the floor is raised in the change that adds them.

Usage:
  test-floor.py [--floor FILE] <builddir>          judge
  test-floor.py --print <builddir>                 the counts, as a floor file

The repository judged is REPO_ROOT, else $GITHUB_WORKSPACE, else the git
checkout around the current directory; a relative builddir or floor file
is read from there.
"""
import json
import os
import re
import subprocess
import sys
from collections import Counter

LINE = re.compile(r"^(\S+)\s+([0-9]+)$")


class Cannot(Exception):
    pass


def repo_root():
    root = os.environ.get("REPO_ROOT") or os.environ.get("GITHUB_WORKSPACE")
    if not root:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=False)
        root = out.stdout.strip() if out.returncode == 0 else ""
    if not root or not os.path.isdir(root):
        raise Cannot("no repository to judge -- set REPO_ROOT, or run inside a checkout")
    return root


def census(build_dir):
    if not os.path.isfile(os.path.join(build_dir, "CTestTestfile.cmake")):
        raise Cannot(f"{build_dir} has no CTestTestfile.cmake -- not a configured build dir")
    try:
        out = subprocess.run(["ctest", "--test-dir", build_dir, "--show-only=json-v1"],
                             capture_output=True, text=True, check=False)
    except OSError as exc:
        raise Cannot(f"cannot run ctest: {exc}")
    if out.returncode != 0:
        raise Cannot(f"ctest --show-only failed with exit {out.returncode}: "
                     f"{out.stderr.strip()[:400]}")
    try:
        tests = json.loads(out.stdout).get("tests") or []
    except ValueError as exc:
        raise Cannot(f"ctest printed no JSON: {exc}")
    if not tests:
        raise Cannot(f"ctest registers no test in {build_dir} -- a build that did not "
                     f"happen, not a test set")
    notbuilt = [t.get("name", "") for t in tests if t.get("name", "").endswith("_NOT_BUILT")]
    if notbuilt:
        raise Cannot(f"{len(notbuilt)} test(s) registered as _NOT_BUILT (first: "
                     f"{notbuilt[0]}) -- a build that did not happen")
    counts = Counter()
    for t in tests:
        cmd = t.get("command") or []
        if not cmd:
            raise Cannot(f"test {t.get('name')!r} has no command -- cannot say whose it is")
        counts[os.path.basename(cmd[0])] += 1
    return counts


def read_floor(path):
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise Cannot(f"no floor file at {path}: {exc.strerror}")
    floor = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        m = LINE.match(line)
        if not m or int(m.group(2)) < 1:
            raise Cannot(f"{path}:{n}: '{line}' is not <binary> <n>, n >= 1")
        if m.group(1) in floor:
            raise Cannot(f"{path}:{n}: {m.group(1)} is listed twice")
        floor[m.group(1)] = int(m.group(2))
    if not floor:
        raise Cannot(f"{path} names no binary -- an empty floor judges nothing")
    return floor


def main(argv):
    args = list(argv)
    floor_file, do_print = "ci/test-floor.txt", False
    while args and args[0].startswith("--"):
        if args[0] == "--print":
            do_print = True
            args.pop(0)
        elif args[0] == "--floor" and len(args) > 1:
            floor_file = args[1]
            del args[:2]
        else:
            break
    if len(args) != 1 or not args[0]:
        print("FATAL: usage: test-floor.py [--floor FILE | --print] <builddir>", file=sys.stderr)
        return 2
    try:
        root = repo_root()
        build_dir = os.path.join(root, args[0])
        counts = census(build_dir)
        if do_print:
            for binary in sorted(counts):
                print(f"{binary} {counts[binary]}")
            return 0
        try:
            floor = read_floor(os.path.join(root, floor_file))
        except Cannot:
            # What this build registers, so the file can be written from the log.
            print(f"this build registers (as a floor file for {floor_file}):")
            for binary in sorted(counts):
                print(f"  {binary} {counts[binary]}")
            raise
    except Cannot as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 2
    rc = 0
    for binary, want in sorted(floor.items()):
        have = counts.get(binary, 0)
        if have == 0:
            print(f"::error::{binary}: the build registers no test from it (floor {want})")
            rc = 1
        elif have < want:
            print(f"::error::{binary}: {have} test(s), floor {want} -- {want - have} lost")
            rc = 1
        else:
            print(f"ok    {binary}: {have} >= {want}")
    for binary in sorted(set(counts) - set(floor)):
        print(f"note  {binary}: {counts[binary]} test(s), no floor in {floor_file}")
    print(f"test-floor: {len(floor)} binar{'y' if len(floor) == 1 else 'ies'} judged, "
          f"{sum(counts.values())} test(s) registered")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
