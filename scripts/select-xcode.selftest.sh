#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# select-xcode.selftest.sh -- the Xcode a repository's .xcode-version names is
# found among the installed ones by the version it reports, not by its bundle
# name; DEVELOPER_DIR is its resolved path and SDKROOT an SDK inside it; every
# way the selection would land on some other Xcode or SDK is refused.
#
# No macOS needed: the applications directory is a fixture and `xcodebuild` /
# `xcrun` are stubs on PATH that answer from the DEVELOPER_DIR they are given.
#
# The script runs under /bin/bash, as the action runs it: on macOS that is the
# bash 3.2 Apple ships, so the macOS leg measures it there although this
# self-test itself needs bash 4. SELECT_XCODE_SELFTEST_BASH names another.
set -uo pipefail
unset GITHUB_ENV
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$here/select-xcode.sh"
W="$(mktemp -d "${TMPDIR:-/var/tmp}/select-xcode-st.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
cases=0 red=0 fails=0
TB="${SELECT_XCODE_SELFTEST_BASH:-/bin/bash}"
echo "select-xcode.sh under $TB: $("$TB" -c 'echo "bash $BASH_VERSION"' 2>&1 | head -n 1)"

# Stubs: an Xcode is <app>/Contents/Developer with a `version` file (what
# xcodebuild -version reports) and an `sdk` file (what xcrun reports as the
# macOS SDK path; @DEV@ stands for the developer directory it was asked about).
mkdir -p "$W/bin"
cat >"$W/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -version ] || exit 64
[ -f "$DEVELOPER_DIR/version" ] || exit 1
printf 'Xcode %s\nBuild version 1A1\n' "$(cat "$DEVELOPER_DIR/version")"
EOF
cat >"$W/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "--sdk macosx --show-sdk-path" ] || exit 64
sed "s|@DEV@|$DEVELOPER_DIR|" "$DEVELOPER_DIR/sdk"
EOF
chmod +x "$W/bin/xcodebuild" "$W/bin/xcrun"

APPS="$W/Applications"
# xcode <bundle name> <version> [sdk path, default inside it]
xcode() {
  mkdir -p "$APPS/$1/Contents/Developer"
  printf '%s\n' "$2" >"$APPS/$1/Contents/Developer/version"
  printf '%s\n' "${3:-@DEV@/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}" >"$APPS/$1/Contents/Developer/sdk"
}
R="$W/repo"; mkdir -p "$R"
run() {
  (cd "$W" && PATH="$W/bin:$PATH" SELECT_XCODE_APPLICATIONS="$APPS" "$TB" "$TOOL" "$@") >"$W/out" 2>"$W/err"
  rc=$?
  cat "$W/out" "$W/err" >"$W/log"
}
expect() {  # expect <label> <want-rc> <needle-in-log>
  cases=$((cases + 1))
  [ "$2" = 0 ] || red=$((red + 1))
  if [ "$rc" = "$2" ] && grep -qF -- "$3" "$W/log"; then echo "ok    $1 (rc=$rc)"
  else echo "FAIL  $1: rc=$rc, want $2 with '$3'"; sed 's/^/  | /' "$W/log"; fails=1; fi
}
check() {  # check <label> <condition...>
  cases=$((cases + 1))
  if "${@:2}"; then echo "ok    $1"; else echo "FAIL  $1"; sed 's/^/  | /' "$W/log"; fails=1; fi
}

# --- a runner image: the default Xcode is another version, the wanted one is
# installed under its number and reached also through a symlinked alias.
echo 27.0 >"$R/.xcode-version"
xcode Xcode.app 26.4
xcode Xcode_27.app 27.0
ln -s Xcode_27.app "$APPS/Xcode_27.0.app"
xcode Xcode_26.4.app 26.4
DEV27="$(cd -P "$APPS/Xcode_27.app/Contents/Developer" && pwd)"
SDK27="$DEV27/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

run --root "$R"
expect "the Xcode .xcode-version names is chosen over the image's default" 0 "Xcode 27.0 at $DEV27"
check "outside Actions it prints DEVELOPER_DIR (resolved) and SDKROOT to eval" \
  grep -qxF "export DEVELOPER_DIR=$DEV27" "$W/out"
check "  ... and SDKROOT inside that Xcode" grep -qxF "export SDKROOT=$SDK27" "$W/out"

: >"$W/github_env"
(cd "$W" && GITHUB_ENV="$W/github_env" PATH="$W/bin:$PATH" SELECT_XCODE_APPLICATIONS="$APPS" "$TB" "$TOOL" --root "$R") >"$W/out" 2>"$W/err"
rc=$?; cat "$W/out" "$W/err" >"$W/log"
expect "in Actions it selects the same Xcode" 0 "Xcode 27.0 at $DEV27"
check "  ... and writes both variables to GITHUB_ENV, nothing to eval" \
  test "$(cat "$W/github_env")" = "DEVELOPER_DIR=$DEV27
SDKROOT=$SDK27" -a ! -s "$W/out"

# --- the root's .xcode-version decides, not this script's checkout
R2="$W/other"; mkdir -p "$R2"; echo 26.4 >"$R2/.xcode-version"
run --root "$R2"
expect "the version is read from --root" 0 "Xcode 26.4 at"

# --- refusals
echo 28.0 >"$R/.xcode-version"
run --root "$R"
expect "a version no installed Xcode reports is refused, not the default taken" 1 "no Xcode 28.0 installed"
check "  ... and the refusal says what is installed" grep -qF "Xcode_27.app=27.0" "$W/log"

# an Xcode named for the version that reports another (a renamed bundle)
echo 27.1 >"$R/.xcode-version"; xcode Xcode_27.1.app 27.0
run --root "$R"
expect "a bundle named 27.1 that reports 27.0 is not Xcode 27.1" 1 "no Xcode 27.1 installed"
rm -rf "$APPS/Xcode_27.1.app"

echo 27.0 >"$R/.xcode-version"
printf '%s\n' /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk >"$DEV27/sdk"
run --root "$R"
expect "an SDK outside the chosen Xcode (Command Line Tools) is refused" 1 "is not inside $DEV27"
printf '%s\n' "@DEV@/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" >"$DEV27/sdk"

printf ' \n' >"$R/.xcode-version"
run --root "$R"
expect "an empty .xcode-version is refused" 1 ".xcode-version is empty"

rm "$R/.xcode-version"
run --root "$R"
expect "no .xcode-version cannot be judged" 2 "no .xcode-version"
run --root "$W/nowhere"
expect "a root that is not a directory cannot be judged" 2 "not a directory"
run --bogus
expect "an unknown argument is a usage error" 2 "usage:"

[ "$fails" = 0 ] || { echo "select-xcode selftest: FAILED"; exit 1; }
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
