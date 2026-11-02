#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Self-test for the canonical CMake modules every repository copies
# (cmake/GitVersion.cmake, cmake/FindOrUseLibreAgent.cmake), configured for
# real against small fixture projects (LANGUAGES NONE, no network: the agent's
# source comes from a FETCHCONTENT_SOURCE_DIR override, the installed agent
# from a fake CONFIG package).
#
#   G1  a tag a major behind VERSION: VERSION's triple, the distance kept
#   G2  a tag ahead of VERSION on the tagged commit: the tag
#   G3  a tree with no .git inside a FOREIGN repository: VERSION, never the
#       enclosing repository's tag
#   G4  no git at all: VERSION
#   F1  source path: the named component and what it needs are on, the rest off
#   F2  the socket client brings the wire and the facade
#   F3  installed path: find_package with this major and exactly the components
#   F4  -D overrides the repository's default
#   F5  no default set by the repository                     -> configure fails
#   F6  two LibreAgent rows in deps.lock                     -> configure fails
#   F7  a row whose revision is not a commit                 -> configure fails
#   F8  an unknown component                                 -> configure fails
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
canon="$here/../cmake"
command -v cmake >/dev/null 2>&1 || { echo "FATAL: cmake is not on PATH -- cannot judge" >&2; exit 2; }
for m in GitVersion.cmake FindOrUseLibreAgent.cmake; do
    [ -f "$canon/$m" ] || { echo "FATAL: no $canon/$m" >&2; exit 2; }
done
W="$(mktemp -d "${TMPDIR:-/var/tmp}/cmake-modules-st.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=s GIT_AUTHOR_EMAIL=s@e GIT_COMMITTER_NAME=s GIT_COMMITTER_EMAIL=s@e

cases=0; red=0; fail=0
want() {  # want <label> <expected> <got>
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 ($3)"; else echo "FAIL $1: want '$2', got '$3'"; sed 's/^/  | /' "$W/log"; fail=1; fi
}
refused() {  # refused <label> <rc> <needle>: a configure that must fail, and say why
    cases=$((cases + 1))
    # CMake wraps a long message across lines, so the needle is matched with
    # line breaks and indentation folded to single spaces.
    if [ "$2" -ne 0 ] && tr -s ' \n' '  ' <"$W/log" | grep -qF -- "$3"; then echo "ok   $1 (rc=$2)"; red=$((red + 1))
    else echo "FAIL $1: rc=$2, want a failure saying '$3'"; sed 's/^/  | /' "$W/log"; fail=1; fi
}
configure() {  # configure <src> [cmake args...]: rc of a fresh configure; log in $W/log
    local src=$1; shift
    rm -rf "$W/b"
    cmake -S "$src" -B "$W/b" "$@" >"$W/log" 2>&1
}

# ── GitVersion ───────────────────────────────────────────────────────────
gitversion_project() {  # gitversion_project <dir>
    mkdir -p "$1/cmake"; cp "$canon/GitVersion.cmake" "$1/cmake/"
    cat >"$1/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.24)
include(cmake/GitVersion.cmake)
project(Fixture VERSION ${GIT_VERSION_MAJOR}.${GIT_VERSION_MINOR}.${GIT_VERSION_PATCH} LANGUAGES NONE)
file(WRITE "${CMAKE_BINARY_DIR}/version.txt" "${GIT_VERSION_FULL} ${PROJECT_VERSION}")
EOF
}
stamped() { cat "$W/b/version.txt" 2>/dev/null; }

R="$W/own"; mkdir -p "$R"; gitversion_project "$R"; echo 5.0.0 >"$R/VERSION"
git -C "$R" init -q; git -C "$R" add -A; git -C "$R" commit -qm a; git -C "$R" tag 4.2.0
echo b >"$R/b"; git -C "$R" add -A; git -C "$R" commit -qm b
echo c >"$R/c"; git -C "$R" add -A; git -C "$R" commit -qm c
sha="$(git -C "$R" rev-parse --short HEAD)"
configure "$R"; want "G1 a tag a major behind VERSION" "5.0.0-2-g$sha 5.0.0" "$(stamped)"
git -C "$R" tag 6.0.0
configure "$R"; want "G2 a tag ahead of VERSION on the tagged commit" "6.0.0 6.0.0" "$(stamped)"

F="$W/foreign"; mkdir -p "$F"; git -C "$F" init -q; echo x >"$F/x"; git -C "$F" add -A; git -C "$F" commit -qm f; git -C "$F" tag 9.9.9
T="$F/vendor/tree"; mkdir -p "$T"; gitversion_project "$T"; echo 5.0.0 >"$T/VERSION"
configure "$T"; want "G3 inside a foreign repository: VERSION, not its tag" "5.0.0 5.0.0" "$(stamped)"
configure "$T" -DGIT_EXECUTABLE=; want "G4 no git at all: VERSION" "5.0.0 5.0.0" "$(stamped)"

# ── FindOrUseLibreAgent ──────────────────────────────────────────────────
# A fake agent source tree: records the switches it was configured with.
A="$W/agent-src"; mkdir -p "$A"
cat >"$A/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.24)
project(LibreAgent LANGUAGES NONE)
set(_s "")
foreach(_x CORE WIRE CLIENT_QT CLIENT_QT_TEST_SUPPORT PKCS11_FACADE PKCS11_SOCKET_CLIENT TEST_SUPPORT)
    if(LIBREAGENT_BUILD_${_x})
        string(APPEND _s "${_x} ")
    endif()
endforeach()
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/../agent-switches.txt" "${_s}")
EOF
# A fake installed agent: records the version and components asked for.
P="$W/prefix/lib/cmake/LibreAgent"; mkdir -p "$P"
cat >"$P/LibreAgentConfig.cmake" <<'EOF'
file(WRITE "${CMAKE_BINARY_DIR}/agent-found.txt" "${LibreAgent_FIND_VERSION_MAJOR} ${LibreAgent_FIND_COMPONENTS}")
EOF
cat >"$P/LibreAgentConfigVersion.cmake" <<'EOF'
set(PACKAGE_VERSION 5.0.0)
if(PACKAGE_FIND_VERSION_MAJOR EQUAL 5)
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
EOF
consumer() {  # consumer <dir> <default|-> <components...>
    local d=$1 def=$2; shift 2
    mkdir -p "$d/cmake"; cp "$canon/FindOrUseLibreAgent.cmake" "$d/cmake/"
    printf 'LibreAgent https://github.com/LibreSCRS/LibreAgent %s\n' 0123456789abcdef0123456789abcdef01234567 >"$d/deps.lock"
    {
        echo 'cmake_minimum_required(VERSION 3.24)'
        echo 'project(Consumer VERSION 5.0.0 LANGUAGES NONE)'
        [ "$def" = - ] || echo "set(LIBRESCRS_AGENT_FROM_SOURCE_DEFAULT $def)"
        echo 'include(cmake/FindOrUseLibreAgent.cmake)'
        echo "librescrs_use_libreagent(COMPONENTS $*)"
    } >"$d/CMakeLists.txt"
}
switches() { tr -s ' ' <"$W/b/_deps/agent-switches.txt" 2>/dev/null | sed 's/ $//'; }
src=(-DFETCHCONTENT_SOURCE_DIR_LIBREAGENT="$A")

C="$W/c1"; consumer "$C" ON ClientQt
configure "$C" "${src[@]}"; want "F1 ClientQt from source: the Qt client and the wire, nothing else" "WIRE CLIENT_QT" "$(switches)"
C="$W/c2"; consumer "$C" ON Pkcs11SocketClient TestSupport
configure "$C" "${src[@]}"; want "F2 the socket client brings the wire and the facade" "WIRE PKCS11_FACADE PKCS11_SOCKET_CLIENT TEST_SUPPORT" "$(switches)"
C="$W/c3"; consumer "$C" OFF Core Wire
configure "$C" -DCMAKE_PREFIX_PATH="$W/prefix"; want "F3 installed: this major, exactly the components" "5 Core;Wire" "$(cat "$W/b/agent-found.txt" 2>/dev/null)"
C="$W/c4"; consumer "$C" ON Core
configure "$C" -DLIBRESCRS_AGENT_FROM_SOURCE=OFF -DCMAKE_PREFIX_PATH="$W/prefix"
want "F4 -D overrides the repository's default" "5 Core" "$(cat "$W/b/agent-found.txt" 2>/dev/null)"
C="$W/c5"; consumer "$C" - Core
configure "$C" "${src[@]}"; refused "F5 no default from the repository" $? "Set LIBRESCRS_AGENT_FROM_SOURCE_DEFAULT"
C="$W/c6"; consumer "$C" ON Core
printf 'LibreAgent https://github.com/LibreSCRS/LibreAgent %s\n' 1111111111111111111111111111111111111111 >>"$C/deps.lock"
configure "$C" "${src[@]}"; refused "F6 two LibreAgent rows" $? "exactly one LibreAgent row (it holds 2)"
C="$W/c7"; consumer "$C" ON Core
printf 'LibreAgent https://github.com/LibreSCRS/LibreAgent main\n' >"$C/deps.lock"
configure "$C" "${src[@]}"; refused "F7 a revision that is not a commit" $? "is not a commit"
C="$W/c8"; consumer "$C" ON Core Gui
configure "$C" "${src[@]}"; refused "F8 an unknown component" $? "unknown component Gui"

if [ "$fail" -eq 0 ]; then echo "cmake-modules selftest: all cases passed"; else echo "cmake-modules selftest: FAILED"; fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fail" -eq 0 ]
