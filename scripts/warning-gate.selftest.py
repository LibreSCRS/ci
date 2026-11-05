#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Prove the warning gate can fail, that it refuses a log that is not a
measurement, and that it can tell one of our diagnostics from a header's.

The case that matters most is the first partition one. Partitioning by the
primary location alone would put a real invalid free of one of our objects into
`system`: operator delete for a member vector is always called from
new_allocator.h, so the defect reports the SAME primary location as the
second-hand diagnostics this tree has today, and the category is already excused
there. Only the rest of the block tells them apart.

Cases:
   1  exactly the baseline                                  -> 0
   2  one more of a known category                          -> 1
   3  a category the baseline has not seen                  -> 1
   4  one fewer                                             -> 0, "stale baseline"
   5  a compiler the baseline does not have                 -> 0, prints a section
   6  a log with three compile lines                        -> 2 (incremental, not a measurement)
   7  no baseline                                           -> 2
   8  a localised message still counts by its [-W] tag      -> 0
   9  --update over a vacuum log is refused                 -> 2, baseline untouched
  10  our file in the inlined-from chain                    -> 1, counted as ours
  11  the same primary, chain entirely in a header          -> 0, counted as a header's
  12  the same tag from another header, no reason           -> 1
  13  growth in the header partition                        -> 1
  14  a frame under _deps/ or build-asan/                   -> 0, not ours
  15  min_compile_units is read per compiler                -> 2
  16  the one-dimensional baseline is read as ours          -> 0
  17  a tagged diagnostic with no location                  -> 2
  18  --require-key on an unknown compiler                  -> 1

The floor, judged inside --check:
  F16 --check over an unreachable floor fails and names the floor,
      instead of refusing the log and blaming the build            -> 1
  F17 --check with a floor of 0                                    -> 1

Where the root comes from (the gate lives in one repository and judges
another; each of these runs it from a directory outside the fixture):
  R1  only GITHUB_WORKSPACE names the tree                         -> 1
  R2  neither, cwd inside the tree                                 -> 1
  R3  neither, cwd outside every checkout                          -> 2
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

GATE = Path(__file__).resolve().parent / "warning-gate.py"
WORK = Path(tempfile.mkdtemp(prefix="warngate-selftest.", dir="/var/tmp"))
# The runner's own checkout must never leak in as the judged repository.
BASE_ENV = {k: v for k, v in os.environ.items()
            if k not in ("REPO_ROOT", "GITHUB_WORKSPACE")}
passed = failed = 0
cases = red = 0

SYS_HDR = "/usr/include/c++/16/bits/new_allocator.h"
OTHER_HDR = "/usr/include/c++/16/bits/stl_vector.h"


def make_log(path, units, warnings):
    lines = []
    for i in range(units):
        lines.append(f"[{i+1}/{units}] Building CXX object lib/CMakeFiles/x.dir/f{i}.cpp.o")
    lines.extend(warnings)
    path.write_text("\n".join(lines) + "\n")


def free_block(chain, header=SYS_HDR):
    """A GCC -Wfree-nonheap-object block: the inlined-from context comes BEFORE
    the diagnostic, which is why reading only the diagnostic line loses it."""
    out = ["In function 'void LibreSCRS::Placeholder::~Placeholder()',"]
    for i, (fn, loc) in enumerate(chain):
        end = ":" if i == len(chain) - 1 else ","
        out.append(f"    inlined from '{fn}' at {loc}{end}")
    out.append(f"{header}:183:66: warning: 'void operator delete(void*, std::size_t)' "
               f"called on unallocated object [-Wfree-nonheap-object]")
    out.append("  183 |         _GLIBCXX_OPERATOR_DELETE(__p, __n * sizeof(_Tp));")
    out.append("      |         ^")
    return out


def make_repo(name, compiler=("GNU", "16.2.1")):
    root = WORK / name
    (root / "ci").mkdir(parents=True)
    cmf = root / "build" / "CMakeFiles" / "4.4.2"
    cmf.mkdir(parents=True)
    (root / "build" / "CMakeCache.txt").write_text("CMAKE_BUILD_TYPE:STRING=Release\n")
    (cmf / "CMakeCXXCompiler.cmake").write_text(
        f'set(CMAKE_CXX_COMPILER_ID "{compiler[0]}")\n'
        f'set(CMAKE_CXX_COMPILER_VERSION "{compiler[1]}")\n')
    return root


def run(root, *args, env=None, cwd=None, build="build"):
    """Judge <root> from WORK, which is not inside it."""
    e = dict(BASE_ENV, REPO_ROOT=str(root)) if env is None else dict(BASE_ENV, **env)
    r = subprocess.run([sys.executable, str(GATE), *args, "--build-dir", str(root / build)],
                       capture_output=True, text=True, cwd=cwd or WORK, env=e)
    return r.returncode, r.stdout + r.stderr


def ninja(root, edges, build="build"):
    """A configured graph with <edges> compile edges."""
    b = root / build
    b.mkdir(parents=True, exist_ok=True)
    text = "".join(f"build x{i}.o: CXX_COMPILER__t_unscanned ../s{i}.cpp\n"
                   for i in range(edges))
    (b / "build.ninja").write_text(text + "build all: phony x0.o\n")


def write_baseline(root, obj):
    (root / "ci").mkdir(exist_ok=True)
    (root / "ci" / "warning-baseline.json").write_text(json.dumps(obj, indent=2) + "\n")


def check(label, expected, actual, extra=True, out=""):
    global passed, failed, cases, red
    cases += 1
    # red-proved: a case in which the gate was to return non-zero on a
    # perturbed input. A proof that never saw the gate fail is not a proof.
    if expected != 0:
        red += 1
    if expected == actual and extra:
        print(f"case {label}: OK   — exit {actual}")
        passed += 1
    else:
        print(f"case {label}: FAIL — expected exit {expected}, got {actual}\n    {out.strip()[:300]}")
        failed += 1


# A baseline that excuses the tag in the header partition, with its reason.
def partitioned(units=620):
    return {"GNU-16": {
        "min_compile_units": units,
        "project": {"-Wcomment": 30},
        "system": {"-Wfree-nonheap-object": 1},
        "system_reasons": {
            f"-Wfree-nonheap-object@{SYS_HDR}:183":
                "the compiler loses the buffer's origin inlining a variant reset"},
    }}


W = ["f.h:1:1: warning: multi-line comment [-Wcomment]"] * 30
try:
    # 1
    r = make_repo("c1"); make_log(r / "build.log", 620, W)
    run(r, "--update", str(r / "build.log"))
    rc, out = run(r, "--check", str(r / "build.log")); check(1, 0, rc, out=out)

    # 2
    r = make_repo("c2"); make_log(r / "build.log", 620, W)
    run(r, "--update", str(r / "build.log"))
    make_log(r / "more.log", 620, W + [W[0]])
    rc, out = run(r, "--check", str(r / "more.log"))
    check(2, 1, rc, "-Wcomment: 31" in out and "baseline 30" in out, out)

    # 3
    r = make_repo("c3"); make_log(r / "build.log", 620, W)
    run(r, "--update", str(r / "build.log"))
    make_log(r / "new.log", 620, W + ["x.cpp:2:2: warning: dangling else [-Wdangling-else]"])
    rc, out = run(r, "--check", str(r / "new.log"))
    check(3, 1, rc, "has not seen" in out, out)

    # 4
    r = make_repo("c4"); make_log(r / "build.log", 620, W)
    run(r, "--update", str(r / "build.log"))
    make_log(r / "fewer.log", 620, W[:-1])
    rc, out = run(r, "--check", str(r / "fewer.log"))
    check(4, 0, rc, "stale baseline" in out, out)

    # 5: another compiler is reported, not judged
    r = make_repo("c5"); make_log(r / "build.log", 620, W)
    run(r, "--update", str(r / "build.log"))
    (r / "build" / "CMakeFiles" / "4.4.2" / "CMakeCXXCompiler.cmake").write_text(
        'set(CMAKE_CXX_COMPILER_ID "GNU")\nset(CMAKE_CXX_COMPILER_VERSION "13.2.0")\n')
    rc, out = run(r, "--check", str(r / "build.log"))
    check(5, 0, rc, "GNU-13" in out and "not in the baseline" in out, out)

    # 6: an incremental build is not a measurement
    r = make_repo("c6"); make_log(r / "build.log", 620, W)
    run(r, "--update", str(r / "build.log"))
    make_log(r / "inc.log", 3, [])
    rc, out = run(r, "--check", str(r / "inc.log"))
    check(6, 2, rc, "incremental build, not a measurement" in out, out)

    # 7
    r = make_repo("c7"); make_log(r / "build.log", 620, W)
    rc, out = run(r, "--check", str(r / "build.log"))
    check(7, 2, rc, "no baseline" in out, out)

    # 8: the diagnostic text is localised; the tag is not
    r = make_repo("c8")
    make_log(r / "build.log", 620,
             ["f.h:1:1: warning: напомена више редова [-Wcomment]"] * 30)
    run(r, "--update", str(r / "build.log"))
    rc, out = run(r, "--check", str(r / "build.log"))
    check(8, 0, rc, "30 ours" in out, out)

    # 9: --update over a vacuum log is refused and changes nothing
    r = make_repo("c9"); make_log(r / "build.log", 620, W)
    run(r, "--update", str(r / "build.log"))
    before = (r / "ci" / "warning-baseline.json").read_bytes()
    make_log(r / "vacuum.log", 0, [])
    rc, out = run(r, "--update", str(r / "vacuum.log"))
    after = (r / "ci" / "warning-baseline.json").read_bytes()
    check(9, 2, rc, before == after, out)

    # --- the partition ----------------------------------------------------
    # 10: OUR file in the chain, same primary location as the excused ones.
    r = make_repo("c10"); write_baseline(r, partitioned())
    make_log(r / "ours.log", 620, W + free_block(
        [("std::_Optional_payload_base<T>::_M_reset()", "/usr/include/c++/16/optional:280:9"),
         ("LibreSCRS::asicSign(char const*)",
          "lib/libresign/src/native/asic_module.cpp:12:5")]))
    rc, out = run(r, "--check", str(r / "ours.log"))
    check(10, 1, rc, "-Wfree-nonheap-object: 1 ours" in out and "has not seen" in out, out)

    # 11: the same primary location, chain entirely inside the header
    r = make_repo("c11"); write_baseline(r, partitioned())
    make_log(r / "hdr.log", 620, W + free_block(
        [("std::_Optional_payload_base<T>::_M_reset()", "/usr/include/c++/16/optional:280:9"),
         ("std::_Variant_storage<T>::_M_reset()", "/usr/include/c++/16/variant:420:7")]))
    rc, out = run(r, "--check", str(r / "hdr.log"))
    check(11, 0, rc, "loses the buffer's origin" in out, out)

    # 12: same tag, another header, no reason of its own
    r = make_repo("c12"); write_baseline(r, partitioned())
    make_log(r / "other.log", 620, W + free_block(
        [("std::vector<T>::~vector()", "/usr/include/c++/16/bits/stl_vector.h:733:15")],
        header=OTHER_HDR))
    rc, out = run(r, "--check", str(r / "other.log"))
    check(12, 1, rc, "no reason recorded" in out and OTHER_HDR in out, out)

    # 13: growth inside the header partition is still a ratchet
    r = make_repo("c13"); write_baseline(r, partitioned())
    blk = free_block([("std::_Variant_storage<T>::_M_reset()",
                       "/usr/include/c++/16/variant:420:7")])
    make_log(r / "grown.log", 620, W + blk + blk)
    rc, out = run(r, "--check", str(r / "grown.log"))
    check(13, 1, rc, "-Wfree-nonheap-object: 2 from a header" in out, out)

    # 14: vendored and build trees are not ours, or vendored code is permanent red
    r = make_repo("c14"); write_baseline(r, partitioned())
    make_log(r / "vendor.log", 620, W + free_block(
        [("testing::Test::Run()", "_deps/googletest-src/googletest/src/gtest.cc:2600:11"),
         ("Generated::run()", "build-asan/generated/shim.cpp:9:1")]))
    rc, out = run(r, "--check", str(r / "vendor.log"))
    check(14, 0, rc, out=out)

    # 15: the floor is read from the compiler's own section
    r = make_repo("c15"); write_baseline(r, partitioned(units=900))
    make_log(r / "short.log", 620, W)
    rc, out = run(r, "--check", str(r / "short.log"))
    check(15, 2, rc, "expects >= 900" in out, out)

    # 16: the shape this file used to write is read as ours, and says so
    r = make_repo("c16")
    write_baseline(r, {"GNU-16": {"-Wcomment": 30}, "min_compile_units": 620})
    make_log(r / "legacy.log", 620, W)
    rc, out = run(r, "--check", str(r / "legacy.log"))
    check(16, 0, rc, "predates the header/ours partition" in out, out)

    # 17: a tagged diagnostic with nowhere to resolve is not a header's by default
    r = make_repo("c17"); write_baseline(r, partitioned())
    make_log(r / "nowhere.log", 620,
             ["warning: something happened [-Wfree-nonheap-object]"])
    rc, out = run(r, "--check", str(r / "nowhere.log"))
    check(17, 2, rc, "no location to resolve" in out, out)

    # 18: on CI, a compiler with no baseline is a failure, not a report
    r = make_repo("c18"); write_baseline(r, partitioned())
    (r / "build" / "CMakeFiles" / "4.4.2" / "CMakeCXXCompiler.cmake").write_text(
        'set(CMAKE_CXX_COMPILER_ID "GNU")\nset(CMAKE_CXX_COMPILER_VERSION "13.2.0")\n')
    make_log(r / "ci.log", 620, W)
    rc, out = run(r, "--check", "--require-key", str(r / "ci.log"))
    check(18, 1, rc, "requires one" in out, out)

    # F16: the same stale floor under --check is named, not blamed on the log
    r = make_repo("f16"); write_baseline(r, partitioned(units=900)); ninja(r, 700)
    make_log(r / "full.log", 700, W)
    rc, out = run(r, "--check", str(r / "full.log"))
    check("F16", 1, rc, "min_compile_units=900" in out and "only 700 compile edges" in out
          and "incremental build" not in out, out)
    # F17: a floor of 0 under --check, with or without a graph
    r = make_repo("f17"); write_baseline(r, partitioned(units=0))
    make_log(r / "full.log", 620, W)
    rc, out = run(r, "--check", str(r / "full.log"))
    check("F17", 1, rc, "anti-vacuum rule is disarmed" in out, out)

    # --- where the root comes from ----------------------------------------
    r = make_repo("r1"); make_log(r / "build.log", 620, W)
    run(r, "--update", str(r / "build.log"))
    make_log(r / "more.log", 620, W + [W[0]])
    rc, out = run(r, "--check", str(r / "more.log"), env={"GITHUB_WORKSPACE": str(r)})
    check("R1", 1, rc, "-Wcomment: 31" in out, out)
    subprocess.run(["git", "init", "-q", str(r)], check=True)
    rc, out = run(r, "--check", str(r / "more.log"), env={}, cwd=r / "build")
    check("R2", 1, rc, "-Wcomment: 31" in out, out)
    nowhere = WORK / "nowhere"; nowhere.mkdir()
    rc, out = run(r, "--check", str(r / "more.log"),
                  env={"GIT_CEILING_DIRECTORIES": str(WORK)}, cwd=nowhere)
    check("R3", 2, rc, "no repository to judge" in out, out)

    print(f"selftest: {passed} passed, {failed} failed")
    print(f"selftest: {cases} cases, {red} red-proved")
finally:
    shutil.rmtree(WORK, ignore_errors=True)

sys.exit(0 if failed == 0 else 1)
