#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
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
[ -n "${STUB_DEAD:-}" ] && exit 125
r="${m[/report]}"
echo liblibrescrs5 >"$r/linted.txt"
printf '%s' "${STUB_LINTIAN:-}" >"$r/lintian.txt"
echo "PASS stub"
exit "${STUB_RC:-0}"
EOF
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH" PKG_DOCKER=docker STUB_LOG="$work/docker.log"
mkdir -p "$work/p" "$work/acc"; printf 'x\n' >"$work/p/liblibrescrs5_5.0.0-1_amd64.debian13.deb"
v() { env "$@" "$tool" --slug debian13 --packages "$work/p" --accepted "$work/acc" >"$work/log" 2>&1; }

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
v STUB_DEAD=1; expect "a container that never ran cannot be judged" 2 $?
mkdir -p "$work/empty"
"$tool" --slug debian13 --packages "$work/empty" >"$work/log" 2>&1; expect "no package cannot be judged" 2 $?
"$tool" --slug nosuchslug --packages "$work/p" >"$work/log" 2>&1; expect "an unknown slug cannot be judged" 2 $?

[ "$fail" -eq 0 ] || { echo "pkg-verify.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
