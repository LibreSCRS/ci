#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-build-rpm.sh -- build a repository's RPM packages INSIDE the slug's
# container (dnf: Fedora; zypper: openSUSE). Run by pkg-gate.sh.
#
# Contract: the exported source tree is the working directory; PKG_OUT
# (default /out) is writable and receives the binary .rpm files and nothing
# else; PKG_UPSTREAM (default /upstream) holds already-built upstream .rpm files,
# flat or one directory per repository. PKG_MANAGER is dnf or zypper, PKG_SLUG
# the distribution slug, PKG_JOBS the build parallelism (default 2).
#
# What differs on openSUSE, and why it is here and not in the spec:
#   * names: the specs say Fedora names; NAMES_MAP below rewrites the ones
#     openSUSE does not provide, in the build's COPY of the spec only;
#   * dist: openSUSE leaves %{?dist} empty, so Tumbleweed and Leap would build
#     identically named files. The dist tag is set to ".<slug>";
#   * generator: openSUSE's %cmake emits -G"Unix Makefiles" unless the builder
#     macro says ninja, and the specs pass -GNinja themselves;
#   * %{_vpath_builddir} is Fedora's name for the CMake build directory and is
#     undefined on openSUSE, whose %cmake leaves %build inside that directory.
#
# No debug packages, on either manager: %debug_package is defined empty, and a
# -debuginfo / -debugsource file that appears anyway fails the build rather
# than riding along into a release.
#
# Self-test entry point (no container, no rpm):
#   pkg-build-rpm.sh --map-spec <spec-in> <spec-out> [<map>]
set -euo pipefail

# Fedora package name -> openSUSE package name(s): every dependency name a
# LibreSCRS spec declares that openSUSE does not resolve by that name. Only
# names openSUSE does NOT provide are listed: openssl-devel, python3-jsonschema,
# pkgconf-pkg-config, systemd-devel, kf6-*-devel and the rest resolve as they
# are (measured with `zypper what-provides` on Tumbleweed and Leap 16.0,
# 2026-09-26). A name missing here fails the build loudly ("nothing provides
# ..."), never silently.
NAMES_MAP='ninja-build                ninja
dbus-daemon                dbus-1-daemon
gtest-devel                gtest gmock
libappstream-glib          appstream-glib
libplasma-devel            libplasma6-devel
plasma-workspace           plasma6-workspace
qt6-qtbase-devel           qt6-base-devel
qt6-qtdeclarative-devel    qt6-declarative-devel
qt6-qtpdf-devel            qt6-pdf-devel
qt6-qtsvg-devel            qt6-svg-devel
qt6-qttools-devel          qt6-tools-devel qt6-linguist-devel
sdbus-cpp-tools            sdbus-cpp-xml2cpp'

# map_spec IN OUT [MAPFILE]: rewrite dependency names per MAPFILE (default the
# map above). A name is a token that
# is not a version operator and does not follow one.
map_spec() {
    local mapfile="${3:-}"
    if [ -z "$mapfile" ]; then mapfile="$(mktemp)"; printf '%s\n' "$NAMES_MAP" >"$mapfile"; fi
    awk -v mapfile="$mapfile" '
        BEGIN {
            while ((getline line < mapfile) > 0) {
                if (line ~ /^[[:space:]]*(#|$)/) continue
                n = split(line, f, /[[:space:]]+/)
                to = f[2]; for (i = 3; i <= n; i++) to = to " " f[i]
                map[f[1]] = to
            }
        }
        /^(BuildRequires|Requires|Recommends|Suggests)(\([^)]*\))?:/ {
            p = index($0, ":"); head = substr($0, 1, p); rest = substr($0, p + 1)
            n = split(rest, t, /[[:space:],]+/); out = ""; prev = ""
            for (i = 1; i <= n; i++) {
                if (t[i] == "") continue
                tok = t[i]; base = tok; suf = ""
                if (match(tok, /%\{\?_isa\}$/)) { base = substr(tok, 1, RSTART - 1); suf = substr(tok, RSTART) }
                if (prev !~ /^(<|<=|=|>=|>)$/ && (base in map)) tok = map[base] suf
                out = out " " tok; prev = t[i]
            }
            print head out; next
        }
        { print }
    ' "$1" >"$2"
    [ -n "${3:-}" ] || rm -f "$mapfile"
}

if [ "${1:-}" = --map-spec ]; then
    [ $# -ge 3 ] || { echo "usage: $0 --map-spec <in> <out> [<map>]" >&2; exit 2; }
    map_spec "$2" "$3" "${4:-}"
    exit 0
fi

MANAGER="${PKG_MANAGER:?PKG_MANAGER must be dnf or zypper}"
SLUG="${PKG_SLUG:?PKG_SLUG is required}"
OUT="${PKG_OUT:-/out}"
UP="${PKG_UPSTREAM:-/upstream}"
JOBS="${PKG_JOBS:-2}"

shopt -s nullglob
specs=( packaging/rpm/*.spec )
shopt -u nullglob
[ "${#specs[@]}" -eq 1 ] || { echo "pkg-build-rpm: want exactly one packaging/rpm/*.spec, found ${#specs[@]}" >&2; exit 1; }
spec="${specs[0]}"

defines=( --define "debug_package %{nil}" --define "_smp_build_ncpus $JOBS" )
case "$MANAGER" in
dnf)
    # Fedora's image enables the Cisco openh264 repository; nothing here needs
    # it and its mirrors fail often enough to redden a run for no reason. It is
    # switched off in the repository file (not with --disablerepo, which dnf5
    # refuses for an id the image no longer has), so every dnf call below --
    # including the ones inside rpm tooling -- skips it.
    for r in "${PKG_DNF_REPO_DIR:-/etc/yum.repos.d}"/fedora-cisco-openh264*.repo; do
        if [ -f "$r" ]; then sed -i "s/^enabled=1/enabled=0/" "$r"; fi
    done
    pm_install() { dnf -y -q install "$@"; }
    # file: brp-strip finds what to strip with it. With debug packages off,
    # brp-strip (strip -g) is the only step that removes debug information;
    # the symbol table stays, which rpmlint reports as an unjudged
    # unstripped-binary-or-object warning.
    dnf -y -q install rpm-build rpmdevtools dnf-plugins-core tar file >/dev/null
    ;;
zypper)
    pm_install() { zypper -n -q --no-gpg-checks install --allow-unsigned-rpm "$@"; }
    zypper -n -q refresh >/dev/null
    pm_install rpm-build tar gzip gawk ninja file >/dev/null
    defines+=( --define "dist .$SLUG" --define "__builder /usr/bin/ninja" --define "_vpath_builddir ." )
    ;;
*) echo "pkg-build-rpm: unknown manager '$MANAGER'" >&2; exit 2 ;;
esac

# After the tools: the Tumbleweed image has no awk until gawk is installed.
name=$(awk '/^Name:/{print $2; exit}' "$spec")
version=$(awk '/^Version:/{print $2; exit}' "$spec")

# Upstream LibreSCRS packages first: build dependencies resolve against them.
# A debug package is never an input.
shopt -s nullglob
upstream=()
for f in "$UP"/*.rpm "$UP"/*/*.rpm; do
    case "$f" in *-debuginfo-*|*-debugsource-*) echo "pkg-build-rpm: refusing debug package input $f" >&2; exit 1 ;; esac
    upstream+=("$f")
done
shopt -u nullglob
if [ "${#upstream[@]}" -gt 0 ]; then
    echo "pkg-build-rpm: installing ${#upstream[@]} upstream package(s)"
    printf '  %s\n' "${upstream[@]}"
    pm_install "${upstream[@]}" >/dev/null
fi

top="$(rpm --eval '%{_topdir}')"
mkdir -p "$top"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

# Source0 is the tarball rpmbuild unpacks, made from the exported tree.
# Explicit excludes only: --exclude-vcs-ignores honours every .gitignore in the
# tree, and the vendored OpenSC ignores *.[0-9] while tracking compat_strlcpy.3.
stage="$(mktemp -d)/$name-$version"
mkdir -p "$stage"
tar --exclude=./.git --exclude=./build --exclude=./debian --exclude='./.github' \
    -cf - . | tar -xf - -C "$stage"
tar -czf "$top/SOURCES/$name-$version.tar.gz" -C "$(dirname "$stage")" "$name-$version"
rm -rf "$(dirname "$stage")"

bspec="$top/SPECS/$(basename "$spec")"
if [ "$MANAGER" = zypper ]; then
    map_spec "$spec" "$bspec"
    echo "pkg-build-rpm: dependency names rewritten for openSUSE:"
    diff "$spec" "$bspec" | sed -n 's/^> /  /p' || true
else
    cp "$spec" "$bspec"
fi

if [ "$MANAGER" = dnf ]; then
    dnf -y -q builddep "${defines[@]}" "$bspec" >/dev/null
else
    mapfile -t brs < <(rpmspec -q --buildrequires "${defines[@]}" "$bspec" | sed -E 's/[[:space:]]+//g')
    [ "${#brs[@]}" -gt 0 ] || { echo "pkg-build-rpm: rpmspec listed no BuildRequires" >&2; exit 1; }
    pm_install "${brs[@]}" >/dev/null
fi

rpmbuild -bb "${defines[@]}" "$bspec"

mkdir -p "$OUT"
mapfile -t built < <(find "$top/RPMS" -name '*.rpm' | sort)
[ "${#built[@]}" -gt 0 ] || { echo "pkg-build-rpm: rpmbuild produced no package" >&2; exit 1; }
for f in "${built[@]}"; do
    case "$f" in
        *-debuginfo-*|*-debugsource-*)
            echo "pkg-build-rpm: debug package produced although disabled: $(basename "$f")" >&2; exit 1 ;;
    esac
done
cp -v "${built[@]}" "$OUT/"
