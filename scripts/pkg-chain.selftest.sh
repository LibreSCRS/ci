#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-chain.sh with docker and gh replaced by stubs: source mode
# builds the upstream at its locked commit first and reuses it, release mode
# downloads only the slug's assets, and an empty or debug-carrying release, a
# failed upstream build or a release build with no version are refused.
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-chain.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-chain-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 HOME="$work"
unset REPO_ROOT GITHUB_WORKSPACE

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; tail -n 25 "$work/log" | sed 's/^/  | /'; fail=1; fi
}

mkdir -p "$work/bin"
# docker: a build writes "<repo-marker>_5.0.0-1_amd64.deb" (the marker is the
# source tree's NAME file) into /out; STUB_FAIL_FOR=<marker> fails that build.
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = run ] || exit 0; shift
declare -A m=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rm) shift ;; -v) IFS=: read -r a b _ <<<"$2"; m[$b]="$a"; shift 2 ;;
    -w|-e|--network) shift 2 ;; *) break ;;
  esac
done
shift
case "$*" in
  "bash /ci-scripts/pkg-build-deb.sh")
    n="$(cat "${m[/s]}/NAME")"
    echo "build $n" >>"$STUB_LOG"
    [ "${STUB_FAIL_FOR:-}" != "$n" ] || exit 1
    printf 'deb\n' >"${m[/out]}/${n}_5.0.0-1_amd64.deb"; exit 0 ;;
  rm\ -rf\ /w/*) rm -rf "${m[/w]}/${3#/w/}"; exit 0 ;;
esac
exit 0
EOF
# gh: `release download V -R R -p PAT -D DIR --clobber` over STUB_ASSETS
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "release download" ] || exit 2
shift 2; ver="$1"; shift
while [ $# -gt 0 ]; do case "$1" in -R) r="$2"; shift 2 ;; -p) pat="$2"; shift 2 ;; -D) d="$2"; shift 2 ;; *) shift ;; esac; done
echo "download $r $ver $pat" >>"$STUB_LOG"
n=0
for a in $STUB_ASSETS; do
  # shellcheck disable=SC2254
  case "$a" in $pat) mkdir -p "$d"; printf 'x\n' >"$d/$a"; n=$((n + 1)) ;; esac
done
[ "$n" -gt 0 ] || { echo "no assets match the file pattern"; exit 1; }
EOF
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" PKG_DOCKER=docker PKG_GH=gh STUB_LOG="$work/stub.log"

mkrepo() {  # mkrepo DIR NAME [deps.lock] -> commit
    rm -rf "$1"; mkdir -p "$1/packaging/debian" "$1/packaging/rpm"
    printf 'Source: %s\nMaintainer: LibreSCRS <librescrs@proton.me>\n' "$2" >"$1/packaging/debian/control"
    printf '#!/usr/bin/make -f\n' >"$1/packaging/debian/rules"
    printf 'Name: %s\n' "$2" >"$1/packaging/rpm/$2.spec"
    printf '%s\n' "$2" >"$1/NAME"
    [ -z "${3:-}" ] || printf '%s\n' "$3" >"$1/deps.lock"
    git -C "$1" init -q -b main && git -C "$1" add -A && git -C "$1" commit -q -m c && git -C "$1" rev-parse HEAD
}
M="$(mkrepo "$work/up/LibreMiddleware" lm)"
mkrepo "$work/c" la "LibreMiddleware $work/up/LibreMiddleware $M main" >/dev/null
chain() { "$tool" build --slug debian13 --art "$work/art" --root "$work/c" --name LibreAgent --dist "$work/dist" "$@" >"$work/log" 2>&1; }

# source: upstream at its locked commit, first; then the consumer; then assets
: >"$STUB_LOG"; chain --upstream source; rc=$?
test "$(tr '\n' ' ' <"$STUB_LOG")" = "build lm build la "; order=$?
test "$(cat "$work/art/debian13/LibreMiddleware/.built-from")" = "$M"; from=$?
test -f "$work/dist/la_5.0.0-1_amd64.debian13.deb" && test ! -e "$work/dist/lm_5.0.0-1_amd64.debian13.deb"; own=$?
expect "source: upstream built first at its lock, only own packages collected" "0 0 0 0" "$rc $order $from $own"
rm -rf "$work/dist"; : >"$STUB_LOG"; chain --upstream source; rc=$?
test "$(tr '\n' ' ' <"$STUB_LOG")" = "build la "; expect "source: an upstream built from the same commit is reused" "0 0" "$rc $?"
rm -rf "$work/art" "$work/dist"; : >"$STUB_LOG"
env STUB_FAIL_FOR=lm "$tool" build --slug debian13 --art "$work/art" --root "$work/c" --name LibreAgent --upstream source >"$work/log" 2>&1; rc=$?
grep -q 'build la' "$STUB_LOG"; expect "source: a failed upstream build stops the chain before the consumer" "1 1" "$rc $?"

# release: the upstream's slug assets only. The closure still reads the
# upstream's own deps.lock at its commit; github.com is redirected to the local
# repository for that.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$work/up/LibreMiddleware.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/LibreSCRS/LibreMiddleware
mkrepo "$work/c" la "LibreMiddleware https://github.com/LibreSCRS/LibreMiddleware $M 5.0.0" >/dev/null
rm -rf "$work/art" "$work/dist"; : >"$STUB_LOG"
STUB_ASSETS="lm_5.0.0-1_amd64.debian13.deb lm_5.0.0-1_amd64.ubuntu2604.deb lm-5.0.0-1.fc43.x86_64.fedora43.rpm" \
    chain --upstream release --version 5.0.0; rc=$?
test "$(find "$work/art/debian13/LibreMiddleware/deb" -type f | xargs -n1 basename)" = "lm_5.0.0-1_amd64.debian13.deb"; only=$?
grep -q 'download LibreSCRS/LibreMiddleware 5.0.0 \*\.debian13\.deb' "$STUB_LOG"; asked=$?
expect "release: exactly the slug's assets of the upstream release" "0 0 0" "$rc $only $asked"
rm -rf "$work/art"; STUB_ASSETS="lm_5.0.0-1_amd64.ubuntu2604.deb" chain --upstream release --version 5.0.0
expect "release: an upstream release without this slug is red" 1 $?
rm -rf "$work/art"; STUB_ASSETS="lm_5.0.0-1_amd64.debian13.deb lm-dbgsym_5.0.0-1_amd64.debian13.deb" chain --upstream release --version 5.0.0
expect "release: an upstream release carrying a debug package is red" 1 $?
chain --upstream release; expect "release without a version cannot be judged" 2 $?
chain --upstream release --version 5.0.0 --ref LibreMiddleware=main; expect "--ref with release cannot be judged" 2 $?
chain --upstream tarball; expect "an unknown upstream mode cannot be judged" 2 $?

# fetch on its own
STUB_ASSETS="a.tar.gz b.tar.gz" "$tool" fetch --repo O/R --version 1 --pattern 'a.tar.gz' --into "$work/fx" >"$work/log" 2>&1; rc=$?
test "$(find "$work/fx" -type f | wc -l)" -eq 1; expect "fetch takes exactly what the pattern names" "0 0" "$rc $?"
STUB_ASSETS="a.tar.gz" "$tool" fetch --repo O/R --version 1 --pattern '*.deb' --into "$work/fx2" >"$work/log" 2>&1
expect "fetch with no match is red" 1 $?

[ "$fail" -eq 0 ] || { echo "pkg-chain.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
