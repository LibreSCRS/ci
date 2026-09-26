#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Self-test for pkg-build-rpm.sh with rpm/rpmbuild/dnf/zypper replaced by
# stubs: openSUSE gets its package names, a slug dist tag, the ninja builder
# and no debug packages; a debug package produced or offered as input fails
# the build with nothing collected.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-build-rpm.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-build-rpm-st.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; tail -n 15 "$work/log" 2>/dev/null | sed 's/^/  | /'; fail=1; fi
}

SPEC='%global _lto_cflags %{nil}
Name:           librescrs-x
Version:        5.0.0
Release:        1%{?dist}
# BuildRequires: ninja-build (a comment, never rewritten)
BuildRequires:  cmake >= 3.24
BuildRequires:  ninja-build
BuildRequires:  qt6-qttools-devel
BuildRequires:  gtest-devel, dbus-daemon
BuildRequires:  librescrs-middleware-devel >= 5.0
Requires:       qt6-qtbase-devel%{?_isa}
Requires:       %{name}%{?_isa} = %{version}-%{release}
Recommends:     librescrs-agent >= 5.0
Summary:        ninja-build is only a word here'

# ── the name map, on its own ──────────────────────────────────────────────
printf '%s\n' "$SPEC" >"$work/in.spec"
"$tool" --map-spec "$work/in.spec" "$work/out.spec"; rc=$?
grep -qx 'BuildRequires: ninja' "$work/out.spec"; a=$?
grep -qx 'BuildRequires: qt6-tools-devel qt6-linguist-devel' "$work/out.spec"; b=$?
grep -qx 'BuildRequires: gtest gmock dbus-1-daemon' "$work/out.spec"; c=$?
grep -qx 'Requires: qt6-base-devel%{?_isa}' "$work/out.spec"; d=$?
grep -qx 'BuildRequires: cmake >= 3.24' "$work/out.spec"; e=$?
expect "Fedora names mapped, versions and %{?_isa} kept" "0 0 0 0 0 0" "$rc $a $b $c $d $e"
grep -qx '# BuildRequires: ninja-build (a comment, never rewritten)' "$work/out.spec" \
    && grep -qx 'Summary:        ninja-build is only a word here' "$work/out.spec" \
    && grep -qx 'Requires: %{name}%{?_isa} = %{version}-%{release}' "$work/out.spec"
expect "comments, other tags and unmapped names untouched" 0 $?
printf 'ninja-build ninja\n' >"$work/one.map"
"$tool" --map-spec "$work/in.spec" "$work/out2.spec" "$work/one.map"
grep -qx 'BuildRequires: qt6-qttools-devel' "$work/out2.spec"; expect "a name missing from the map stays as it is (and fails loudly at install)" 0 $?

# ── the build, with stubs ─────────────────────────────────────────────────
mkdir -p "$work/bin"
cat >"$work/bin/rpm" <<'EOF'
#!/bin/sh
[ "$1" = --eval ] && [ "$2" = '%{_topdir}' ] && { echo "$STUB_TOP"; exit 0; }
exit 0
EOF
cat >"$work/bin/rpmspec" <<'EOF'
#!/bin/sh
grep '^BuildRequires:' "$(eval echo \${$#})" | sed 's/^BuildRequires:[[:space:]]*//; s/,/\n/g' | sed 's/^ *//'
EOF
cat >"$work/bin/zypper" <<'EOF'
#!/bin/sh
echo "zypper $*" >>"$STUB_REC/pm"
EOF
cat >"$work/bin/dnf" <<'EOF'
#!/bin/sh
echo "dnf $*" >>"$STUB_REC/pm"
EOF
cat >"$work/bin/rpmbuild" <<'EOF'
#!/bin/sh
echo "$*" >"$STUB_REC/rpmbuild"
mkdir -p "$STUB_TOP/RPMS/x86_64"
[ -n "${STUB_NONE:-}" ] && exit 0
: >"$STUB_TOP/RPMS/x86_64/librescrs-x-5.0.0-1.x86_64.rpm"
[ -n "${STUB_DEBUG:-}" ] && : >"$STUB_TOP/RPMS/x86_64/librescrs-x-debuginfo-5.0.0-1.x86_64.rpm"
exit 0
EOF
chmod +x "$work/bin"/*

tree() {
    rm -rf "$work/t" "$work/out" "$work/up" "$work/rec" "$work/top"
    mkdir -p "$work/t/packaging/rpm" "$work/out" "$work/up" "$work/rec" "$work/top"
    printf '%s\n' "$SPEC" >"$work/t/packaging/rpm/librescrs-x.spec"
}
build() {  # build <manager> [env...]
    local m="$1"; shift
    ( cd "$work/t" && env PATH="$work/bin:$PATH" STUB_REC="$work/rec" STUB_TOP="$work/top" \
        PKG_MANAGER="$m" PKG_SLUG="${SLUG:-opensusetw}" PKG_OUT="$work/out" PKG_UPSTREAM="$work/up" TMPDIR="$work" "$@" bash "$tool" ) >"$work/log" 2>&1
}

tree; build zypper; rc=$?
grep -q -- '--define dist .opensusetw' "$work/rec/rpmbuild"; dist=$?
grep -q -- '--define debug_package %{nil}' "$work/rec/rpmbuild"; dbg=$?
grep -q -- '--define __builder /usr/bin/ninja' "$work/rec/rpmbuild"; gen=$?
test -f "$work/out/librescrs-x-5.0.0-1.x86_64.rpm"; got=$?
expect "openSUSE build: slug dist tag, ninja, no debug package, package collected" "0 0 0 0 0" "$rc $dist $dbg $gen $got"
grep -q 'install .* ninja ' "$work/rec/pm" && ! grep -q 'ninja-build' "$work/rec/pm"
expect "openSUSE installs the mapped build dependencies" 0 $?
tree; SLUG=fedora43 build dnf; rc=$?
! grep -q -- '--define dist' "$work/rec/rpmbuild" && grep -q -- '--define debug_package %{nil}' "$work/rec/rpmbuild"
expect "Fedora build keeps its own dist tag, still no debug package" "0 0" "$rc $?"

red_case() {  # red_case <name> <manager> [env...]
    local name="$1"; shift
    build "$@"; local rc=$?
    local n; n=$(find "$work/out" -type f | wc -l)
    expect "$name (collected: $n)" "1 0" "$rc $n"
}
tree; red_case "a -debuginfo produced anyway fails the build" zypper STUB_DEBUG=1
tree; red_case "a -debuginfo produced anyway fails the Fedora build" dnf STUB_DEBUG=1
tree; : >"$work/up/librescrs-middleware-debugsource-5.0.0-1.x86_64.rpm"
red_case "a debug package offered as upstream input fails the build" zypper
tree; red_case "no package produced fails the build" zypper STUB_NONE=1
tree; cp "$work/t/packaging/rpm/librescrs-x.spec" "$work/t/packaging/rpm/second.spec"
red_case "two specs is red" zypper
tree; build yum; expect "an unknown manager cannot be judged" 2 $?

[ "$fail" -eq 0 ] || { echo "pkg-build-rpm.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
