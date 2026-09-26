#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Self-test for pkg-build-deb.sh with the Debian tools replaced by stubs: the
# build always runs with noautodbgsym, the changelog is generated with the
# project maintainer, and a debug package -- produced or offered as input --
# fails the build with nothing collected.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-build-deb.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-build-deb-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; tail -n 15 "$work/log" | sed 's/^/  | /'; fail=1; fi
}

mkdir -p "$work/bin"
for t in apt-get mk-build-deps; do printf '#!/bin/sh\nexit 0\n' >"$work/bin/$t"; done
cat >"$work/bin/dpkg-buildpackage" <<'EOF'
#!/bin/sh
printf '%s\n' "$DEB_BUILD_OPTIONS" >"$STUB_REC/options"
cp debian/changelog "$STUB_REC/changelog"
[ -n "${STUB_NONE:-}" ] && exit 0
printf 'deb\n' >../librescrs-x_5.0.0-1_amd64.deb
printf 'x\n' >../librescrs-x_5.0.0-1_amd64.changes
[ -n "${STUB_DBGSYM:-}" ] && printf 'dbg\n' >../librescrs-x-dbgsym_5.0.0-1_amd64.deb
[ -n "${STUB_DDEB:-}" ] && printf 'dbg\n' >../librescrs-x-dbgsym_5.0.0-1_amd64.ddeb
exit 0
EOF
chmod +x "$work/bin"/*

tree() {  # tree [headline]
    rm -rf "$work/t" "$work/out" "$work/up" "$work/rec"; mkdir -p "$work/t/src/packaging/debian" "$work/out" "$work/up" "$work/rec"
    printf 'Source: librescrs-x\nMaintainer: LibreSCRS <librescrs@proton.me>\n' >"$work/t/src/packaging/debian/control"
    printf '#!/usr/bin/make -f\n' >"$work/t/src/packaging/debian/rules"
    printf '5.0.0\n' >"$work/t/src/VERSION"
    printf '## 5.0.0\n- **%s**\n' "${1:-Packages for every distribution.}" >"$work/t/src/CHANGELOG.md"
}
build() {
    ( cd "$work/t/src" && env PATH="$work/bin:$PATH" STUB_REC="$work/rec" PKG_OUT="$work/out" \
        PKG_UPSTREAM="$work/up" PKG_JOBS=4 SOURCE_DATE_EPOCH=0 "$@" bash "$tool" ) >"$work/log" 2>&1
}

tree; build; rc=$?
grep -qw noautodbgsym "$work/rec/options"; nd=$?
grep -qw 'parallel=4' "$work/rec/options"; par=$?
test -f "$work/out/librescrs-x_5.0.0-1_amd64.deb" -a ! -e "$work/out/librescrs-x_5.0.0-1_amd64.changes"; only=$?
expect "green build: noautodbgsym, parallel, only the .deb collected" "0 0 0 0" "$rc $nd $par $only"
grep -q '^ -- LibreSCRS <librescrs@proton.me>  ' "$work/rec/changelog"; expect "changelog generated with the project maintainer" 0 $?
tree; build DEB_BUILD_OPTIONS=nocheck; rc=$?
grep -qw noautodbgsym "$work/rec/options" && grep -qw nocheck "$work/rec/options"; expect "caller options kept, noautodbgsym still added" "0 0" "$rc $?"

red_case() {  # red_case <name> <env...>
    local name="$1"; shift
    build "$@"; local rc=$?
    local n; n=$(find "$work/out" -type f | wc -l)
    expect "$name (collected: $n)" "1 0" "$rc $n"
}
tree; red_case "a -dbgsym .deb produced anyway fails the build" STUB_DBGSYM=1
tree; red_case "a .ddeb produced anyway fails the build" STUB_DDEB=1
tree; printf 'x\n' >"$work/up/liblibrescrs5-dbgsym_5.0.0-1_amd64.deb"
red_case "a debug package offered as upstream input fails the build"
tree; red_case "no package produced fails the build" STUB_NONE=1
tree 'Removed src/utils/utils.h.'; red_case "an internal path in the release headline stops the build"

[ "$fail" -eq 0 ] || { echo "pkg-build-deb.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
