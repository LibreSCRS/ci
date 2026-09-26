#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-verify.sh with docker replaced by a stub standing in for
# the container run: a red smoke check and an unaccepted lint finding each make
# the verdict red; a run that produced no report, an empty package set and an
# unknown slug cannot be judged.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-verify.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-verify-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; tail -n 15 "$work/log" | sed 's/^/  | /'; fail=1; fi
}

mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = run ] || exit 0; shift
declare -A m=()
while [ $# -gt 0 ]; do
  case "$1" in --rm) shift ;; -v) IFS=: read -r a b _ <<<"$2"; m[$b]="$a"; shift 2 ;; -e|--network) shift 2 ;; *) break ;; esac
done
echo "$1 ${*:2}" >>"$STUB_LOG"
for k in "${!m[@]}"; do echo "$k=${m[$k]}"; done | sort >"$STUB_LOG.mounts"
[ -n "${STUB_DEAD:-}" ] && exit 125
r="${m[/report]}"
# like the container: lint every package, or only those lint-files.txt names
if [ -f "$r/lint-files.txt" ]; then sed 's/_.*//' "$r/lint-files.txt" >"$r/linted.txt"
else printf 'liblibrescrs5\nlibrescrs-agent\n' >"$r/linted.txt"; fi
: >"$r/lintian.txt"
while IFS= read -r l; do
  [ -n "$l" ] || continue
  p="${l#?: }"; p="${p%%:*}"
  grep -qx "$p" "$r/linted.txt" && printf '%s\n' "$l" >>"$r/lintian.txt"
done <<<"${STUB_LINTIAN:-}"
echo "PASS stub"
exit "${STUB_RC:-0}"
EOF
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH" PKG_DOCKER=docker STUB_LOG="$work/docker.log"
mkdir -p "$work/p/LibreMiddleware" "$work/p/LibreLinux" "$work/acc"
printf 'x\n' >"$work/p/LibreMiddleware/liblibrescrs5_5.0.0-1_amd64.deb"
printf 'x\n' >"$work/p/LibreLinux/librescrs-agent_5.0.0-1_amd64.deb"
v() {  # v [ENV=VAL...] [tool args...]
    local e=()
    while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do e+=("$1"); shift; done
    env "${e[@]}" "$tool" --slug debian13 --packages "$work/p" --accepted "$work/acc" "$@" >"$work/log" 2>&1
}

v; rc=$?
grep -q 'debian:13@sha256:[0-9a-f]\{64\} bash /ci-scripts/pkg-verify-inside.sh' "$work/docker.log"; expect "green stack in a clean container of the slug's image" "0 0" "$rc $?"
v STUB_RC=1; expect "a red smoke check is red" 1 $?
v STUB_LINTIAN='W: liblibrescrs5: package-name-doesnt-match-sonames libLibreSCRS-Core5
'; expect "an unaccepted lint finding is red" 1 $?
printf 'lintian * embedded-library * -- OpenSSL is linked statically on purpose (README-bundling.md)\n' >"$work/acc/liblibrescrs5.txt"
v STUB_LINTIAN='W: liblibrescrs5: embedded-library usr/lib/x/libLibreSCRS_Core.so.5: openssl
'; expect "an accepted bundling finding is green" 0 $?
v; expect "an accepted row with nothing left to accept is red" 1 $?
rm -f "$work/acc/liblibrescrs5.txt"
UP='W: liblibrescrs5: package-name-doesnt-match-sonames libLibreSCRS-Core5
'
v STUB_LINTIAN="$UP"; expect "an upstream finding is judged when every package is linted" 1 $?
v STUB_LINTIAN="$UP" --lint "$work/p/LibreLinux"; rc=$?
expect "with the consumer's scope the upstream finding is not judged" 0 "$rc"
v STUB_LINTIAN='W: librescrs-agent: depends-on-obsolete-package policykit-1
' --lint "$work/p/LibreLinux"; expect "the consumer's own finding is still judged in its scope" 1 $?
mkdir -p "$work/p/LibreEmpty"
v --lint "$work/p/LibreEmpty"; expect "a scope with no package cannot be judged" 2 $?
v STUB_DEAD=1; expect "a container that never ran cannot be judged" 2 $?
mkdir -p "$work/empty"
"$tool" --slug debian13 --packages "$work/empty" >"$work/log" 2>&1; expect "no package cannot be judged" 2 $?
"$tool" --slug nosuchslug --packages "$work/p" >"$work/log" 2>&1; expect "an unknown slug cannot be judged" 2 $?

# --hook: the consumer's assertions ride in the same container, own packages
# at /pkg and each upstream's at /pkg-<Repository>.
mkdir -p "$work/h/LibreLinux/deb" "$work/h/LibreMiddleware/deb"
printf 'x\n' >"$work/h/LibreLinux/deb/librescrs-agent_5.0.0-1_amd64.deb"
printf 'x\n' >"$work/h/LibreMiddleware/deb/liblibrescrs5_5.0.0-1_amd64.deb"
printf '#!/bin/sh\n' >"$work/hook.sh"
hv() { "$tool" --slug debian13 --packages "$work/h" --accepted "$work/acc" "$@" >"$work/log" 2>&1; }
hv --hook "$work/hook.sh" --name LibreLinux; rc=$?
grep -qx "/pkg=$work/h/LibreLinux/deb" "$work/docker.log.mounts" \
  && grep -qx "/pkg-LibreMiddleware=$work/h/LibreMiddleware/deb" "$work/docker.log.mounts" \
  && grep -qx "/hook.sh=$work/hook.sh" "$work/docker.log.mounts"
expect "the hook is mounted into the one container with /pkg and /pkg-<Repository>" "0 0" "$rc $?"
hv --hook "$work/hook.sh" --name LibreKDE; expect "a hook whose repository has no packages cannot be judged" 2 $?
hv --hook "$work/nohook.sh" --name LibreLinux; expect "a hook that is not a file cannot be judged" 2 $?
hv --hook "$work/hook.sh"; expect "a hook without --name cannot be judged" 2 $?
v; rc=$?; grep -q '^/hook.sh=' "$work/docker.log.mounts"; expect "no hook, nothing mounted for one" "0 1" "$rc $?"

[ "$fail" -eq 0 ] || { echo "pkg-verify.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
