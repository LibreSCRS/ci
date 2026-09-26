#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# make-sbom.selftest.sh -- a tree carrying every probe's input gives a bill
# naming each at the version read from the tree; a statically linked upstream
# at its lock adds itself and what it bundles; every way a bill would be
# wrong or empty is refused.
set -uo pipefail
# sedi <expr> <file>: edit in place on GNU and BSD sed alike (BSD `sed -i` takes
# the expression as a backup suffix and leaves the file as it was), and refuse
# a perturbation that changed nothing.
sedi() {
  sed -e "$1" "$2" >"$2.sedi" || { echo "FATAL: sed failed on $2" >&2; exit 2; }
  if cmp -s "$2" "$2.sedi"; then echo "FATAL: perturbation '$1' changed nothing in $2" >&2; exit 2; fi
  mv -f "$2.sedi" "$2"
}
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$here/make-sbom"
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is not on PATH" >&2; exit 2; }
W="$(mktemp -d "/var/tmp/make-sbom-st.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
export GIT_AUTHOR_NAME=s GIT_AUTHOR_EMAIL=s@e GIT_COMMITTER_NAME=s GIT_COMMITTER_EMAIL=s@e
cases=0 red=0 fails=0
QC=930708bb86481e88879eb1d87fd4d664f1d69503
OSC=07d0d40b0e4051f6fe11f3a92cec56d320670d85

run() { (cd "$W" && bash "$TOOL" "$@") >"$W/log" 2>&1; rc=$?; }
# expect <label> <want-rc> <needle-in-log> -- after run
expect() {
  cases=$((cases + 1))
  [ "$2" = 0 ] || red=$((red + 1))
  if [ "$rc" = "$2" ] && grep -qF -- "$3" "$W/log"; then echo "ok    $1 (rc=$rc)"
  else echo "FAIL  $1: rc=$rc, want $2 with '$3'"; sed 's/^/  | /' "$W/log"; fails=1; fi
}
# comp <file> <name> -> "version purl" of that component, or nothing
comp() { python3 -c 'import json,sys
for c in json.load(open(sys.argv[1]))["components"]:
    if c["name"] == sys.argv[2]: print(c["version"], c["purl"])' "$1" "$2"; }

# A middleware-like tree: every probe has its input.
M="$W/Mid"
mkdir -p "$M/thirdparty/openssl-3.5.8" "$M/thirdparty/nlohmann" "$M/thirdparty/miniz" \
         "$M/thirdparty/curl-source/include/curl" "$M/packaging/arch" "$M/cmake"
echo 5.0.0 >"$M/VERSION"
printf '#define NLOHMANN_JSON_VERSION_MAJOR 3\n#define NLOHMANN_JSON_VERSION_MINOR 12\n#define NLOHMANN_JSON_VERSION_PATCH 0\n' >"$M/thirdparty/nlohmann/json.hpp"
echo 3.1.2 >"$M/thirdparty/miniz/VERSION.txt"
printf '#define LIBCURL_VERSION_MAJOR 8\n#define LIBCURL_VERSION_MINOR 16\n#define LIBCURL_VERSION_PATCH 0\n' >"$M/thirdparty/curl-source/include/curl/curlver.h"
git -C "$M/thirdparty/curl-source" init -q && git -C "$M/thirdparty/curl-source" add -A && git -C "$M/thirdparty/curl-source" commit -qm c
CURL="$(git -C "$M/thirdparty/curl-source" rev-parse HEAD)"
printf 'source=("x::https://github.com/OpenSC/OpenSC/archive/%s.tar.gz"\n  "y::https://github.com/curl/curl/archive/%s.tar.gz")\n' "$OSC" 1111111111111111111111111111111111111111 >"$M/packaging/arch/PKGBUILD"

run --root "$M" --repo Mid --out "$W/m.json" --require openssl --require curl --require opensc --require nlohmann-json --require miniz
expect "every probe finds its component" 0 "5 components"
[ "$(comp "$W/m.json" openssl)" = "3.5.8 pkg:generic/openssl@3.5.8" ] \
  && [ "$(comp "$W/m.json" curl)" = "8.16.0 pkg:github/curl/curl@$CURL" ] \
  && [ "$(comp "$W/m.json" opensc)" = "git-$OSC pkg:github/OpenSC/OpenSC@$OSC" ] \
  && [ "$(comp "$W/m.json" nlohmann-json)" = "3.12.0 pkg:github/nlohmann/json@v3.12.0" ] \
  && [ "$(comp "$W/m.json" miniz)" = "3.1.2 pkg:github/richgel999/miniz@3.1.2" ] \
  && python3 "$here/check-sbom" "$W/m.json" >/dev/null
st=$?; cases=$((cases + 1))
if [ "$st" = 0 ]; then echo "ok    versions and commits are the tree's, and check-sbom accepts the bill"
else echo "FAIL  versions and commits are the tree's"; cat "$W/m.json"; fails=1; fi

# the curl commit is the submodule's, not the recipe's (the recipe is a consumer)
cases=$((cases + 1))
if [ "$(comp "$W/m.json" curl | cut -d' ' -f2)" != "pkg:github/curl/curl@1111111111111111111111111111111111111111" ]; then
  echo "ok    curl's commit is the submodule's, not the recipe's copy"
else echo "FAIL  curl's commit came from the recipe"; fails=1; fi

rm "$M/thirdparty/miniz/VERSION.txt"; printf '#define MZ_VERSION "11.3.2"\n' >"$M/thirdparty/miniz/miniz.h"
run --root "$M" --repo Mid --out "$W/m2.json"
cases=$((cases + 1))
if [ "$rc" = 0 ] && [ "$(comp "$W/m2.json" miniz | cut -d' ' -f1)" = 11.3.2 ]; then echo "ok    miniz falls back to MZ_VERSION"
else echo "FAIL  miniz falls back to MZ_VERSION"; fails=1; fi

mkdir -p "$M/thirdparty/openssl-3.6.0"
run --root "$M" --repo Mid --out "$W/m3.json"
expect "two OpenSSL trees are refused, not the first one published" 1 "2 thirdparty/openssl-*"
rmdir "$M/thirdparty/openssl-3.6.0"

# --- an empty or incomplete bill -------------------------------------------
E="$W/Empty"; mkdir -p "$E"; echo 5.0.0 >"$E/VERSION"
run --root "$E" --out "$W/e.json"
expect "a tree that bundles nothing gives no bill" 1 "no components"
[ ! -e "$W/e.json" ] || { echo "FAIL  the refused bill was written"; fails=1; }
rm -rf "$M/thirdparty/openssl-3.5.8"
run --root "$M" --repo Mid --out "$W/m4.json" --require openssl
expect "a required component the tree lost is refused" 1 "not found in the tree: openssl"

# --- a statically linked upstream ------------------------------------------
A="$W/Agent"; mkdir -p "$A/cmake"
printf 'FetchContent_Declare(qcbor\n  GIT_TAG %s\n)\n' "$QC" >"$A/cmake/FetchQCBOR.cmake"
git -C "$A" init -q && git -C "$A" add -A && git -C "$A" commit -qm a
LA="$(git -C "$A" rev-parse HEAD)"
L="$W/Linux"; mkdir -p "$L"; echo 5.0.0 >"$L/VERSION"
printf 'LibreMiddleware https://github.com/LibreSCRS/LibreMiddleware %s\nLibreAgent https://github.com/LibreSCRS/LibreAgent %s\n' "$OSC" "$LA" >"$L/deps.lock"
GITHUB_REPOSITORY=LibreSCRS/LibreLinux run --root "$L" --out "$W/l.json" --static-dep "LibreAgent=$A" --require libreagent --require qcbor
expect "a static upstream at its lock adds itself and what it bundles" 0 "2 components (libreagent, qcbor)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["metadata"]["component"]["name"]=="LibreLinux"; assert d["metadata"]["component"]["version"]=="5.0.0"' "$W/l.json" \
  || { echo "FAIL  metadata names the repository and VERSION"; fails=1; }
[ "$(comp "$W/l.json" libreagent)" = "git-$LA pkg:github/LibreSCRS/LibreAgent@$LA" ] || { echo "FAIL  the upstream component is the locked commit"; fails=1; }

echo moved >"$A/x"; git -C "$A" add -A; git -C "$A" commit -qm moved
run --root "$L" --out "$W/l2.json" --static-dep "LibreAgent=$A"
expect "a static upstream checkout off its lock is refused" 1 "deps.lock locks LibreAgent at $LA"
git -C "$A" reset -q --hard HEAD~1
run --root "$L" --out "$W/l3.json" --static-dep "LibreDarwin=$A"
expect "a static upstream with no deps.lock row is refused" 1 "has no LibreDarwin row"
mkdir -p "$W/plain"
run --root "$L" --out "$W/l4.json" --static-dep "LibreAgent=$W/plain"
expect "a static upstream that is not a checkout is refused" 1 "not a git checkout"
sedi "s/$QC/not-a-pin/" "$A/cmake/FetchQCBOR.cmake"
run --root "$L" --out "$W/l5.json" --static-dep "LibreAgent=$A" --require qcbor
expect "an upstream that lost its QCBOR pin is refused where qcbor is required" 1 "not found in the tree: qcbor"

# --- cannot judge -----------------------------------------------------------
run --root "$M" --repo Mid
expect "no --out is a usage error" 2 "usage:"
rm "$E/VERSION"; run --root "$E" --out "$W/x.json"
expect "no VERSION cannot be judged" 2 "no VERSION"
run --root "$W/nowhere" --out "$W/x.json"
expect "no repository cannot be judged" 2 "no repository"

[ "$fails" = 0 ] || { echo "make-sbom selftest: FAILED"; exit 1; }
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
