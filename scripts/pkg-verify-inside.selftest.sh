#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Self-test for pkg-verify-inside.sh outside a container: the package managers,
# p11-kit, ldd, pkcs11-tool and systemd-analyze are stubs over a fake root.
# A green stack passes for apt, dnf and zypper; two registered providers, a
# D-Bus file off the daemon's path, an unresolved library, a failing
# pkcs11-tool, a unit the verifier rejects, and a manager whose bare install
# switches providers where the contract says it refuses, are each red.
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/pkg-verify-inside.sh"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-verify-inside-st.XXXXXX")" || exit 2
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT

cases=0; red=0; fail=0
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok   $1 (rc=$3)"; [ "${3%% *}" = 1 ] && red=$((red + 1))
    else echo "FAIL $1: want rc=$2, got rc=$3"; grep -E '^(FAIL|INFO)' "$work/log" | sed 's/^/  | /'; fail=1; fi
}

B="$work/bin"; mkdir -p "$B"
# ── the stub world ────────────────────────────────────────────────────────
# A fake package is a text file: "name N", "conflicts N", "file PATH KIND"
# (KIND: elf | elf-missing | text | bad-unit), "module NAME PATH".
cat >"$B/stubpm" <<'EOF'
#!/usr/bin/env bash
# stubpm <manager> <args...>: install fake package files into STUB_ROOT.
mgr="$1"; shift
S="$STUB_STATE"; R="$STUB_ROOT"; mkdir -p "$S"
force=0; files=()
for a in "$@"; do
  case "$a" in --allowerasing|--force-resolution) force=1 ;; -*) ;; *) [ -f "$a" ] && files+=("$a") ;; esac
done
[ "${#files[@]}" -gt 0 ] || exit 0          # distribution tools: always "installed"
field() { sed -n "s/^$1 //p" "$2"; }
for f in "${files[@]}"; do
  n="$(field name "$f")"
  for c in $(field conflicts "$f"); do
    if [ -f "$S/$c" ]; then
      if [ "$mgr" != apt ] && [ "$force" = 0 ] && [ -z "${STUB_BARE_SWITCHES:-}" ]; then
        echo "Problem: $n conflicts with $c"; exit 1
      fi
      while read -r p; do rm -f "$p"; done <"$S/$c"; rm -f "$S/$c"
    fi
  done
done
for f in "${files[@]}"; do
  n="$(field name "$f")"; : >"$S/$n"
  while read -r kind p k; do
    case "$kind" in
      file) mkdir -p "$(dirname "$R$p")"
            case "$k" in elf) echo ELF >"$R$p" ;; elf-missing) printf 'ELF\nMISSING\n' >"$R$p" ;;
                         bad-unit) echo BAD >"$R$p" ;; *) echo text >"$R$p" ;; esac
            echo "$R$p" >>"$S/$n" ;;
      module) mkdir -p "$R/usr/share/p11-kit/modules"
              echo "module: $k" >"$R/usr/share/p11-kit/modules/$p.module"
              echo "$R/usr/share/p11-kit/modules/$p.module" >>"$S/$n" ;;
    esac
  done <"$f"
done
EOF
cat >"$B/apt-get" <<'EOF'
#!/usr/bin/env bash
case "$1" in update) exit 0 ;; esac
exec stubpm apt "$@"
EOF
printf '#!/usr/bin/env bash\n[ "$1" = -n ] && [ "$2" = -q ] && [ "$3" = refresh ] && exit 0\nexec stubpm zypper "$@"\n' >"$B/zypper"
printf '#!/usr/bin/env bash\nexec stubpm dnf "$@"\n' >"$B/dnf"
cat >"$B/dpkg-query" <<'EOF'
#!/usr/bin/env bash
[ -f "$STUB_STATE/${!#}" ] && printf 'ii '
EOF
cat >"$B/dpkg" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -L ] && [ -f "$STUB_STATE/$2" ] && cat "$STUB_STATE/$2"
EOF
cat >"$B/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
sed -n 's/^name //p' "$2"
EOF
cat >"$B/rpm" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -qp) sed -n 's/^name //p' "${!#}" ;;
  -ql) [ -f "$STUB_STATE/$2" ] && cat "$STUB_STATE/$2" ;;
  -q)  [ -f "$STUB_STATE/$2" ] ;;
esac
EOF
cat >"$B/p11-kit" <<'EOF'
#!/usr/bin/env bash
for m in "$STUB_ROOT"/usr/share/p11-kit/modules/*.module; do
  [ -e "$m" ] || continue
  echo "module: $(basename "$m" .module)"; echo "    path: $(sed -n 's/^module: //p' "$m")"
done
EOF
printf '#!/usr/bin/env bash\ngrep -q "^ELF" "${!#}" && echo "ELF 64-bit LSB shared object" || echo "ASCII text"\n' >"$B/file"
printf '#!/usr/bin/env bash\ngrep -q MISSING "$1" && echo "\tlibgone.so.1 => not found"; exit 0\n' >"$B/ldd"
cat >"$B/pkcs11-tool" <<'XEOF'
#!/usr/bin/env bash
case "${STUB_P11TOOL:-slots}" in
  slots) echo "Available slots:"; echo "Slot 0 (0x0): reader"; exit 0 ;;
  none)  echo "Available slots:"; echo "No slots."; exit 1 ;;
  error) echo "error: PKCS11 function C_Initialize failed: rv = CKR_GENERAL_ERROR (0x5)"; exit 1 ;;
  load)  echo "Available slots:"; echo "error: cannot load module"; exit 1 ;;
esac
XEOF
printf '#!/usr/bin/env bash\ngrep -q BAD "${!#}" && { echo "$(basename "${!#}"): Command /usr/libexec/librescrs-agent is not executable"; exit 1; }; exit 0\n' >"$B/systemd-analyze"
for t in lintian rpmlint; do printf '#!/bin/sh\nexit 0\n' >"$B/$t"; done
printf '#!/bin/sh\nexit 0\n' >"$B/timeout.real"
cat >"$B/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
chmod +x "$B"/*

# ── the stack ─────────────────────────────────────────────────────────────
stack() {  # stack <ext> [extra-kind...]: write the fake packages
    local e="$1" p="$work/pkgs/0"; shift
    rm -rf "$work/pkgs" "$work/root" "$work/state" "$work/report"; mkdir -p "$p" "$work/root" "$work/report"
    local noconf="" lib=elf dbus=/usr/share/dbus-1/services/org.librescrs.Agent.service unit=text extra=""
    for k in "$@"; do
        case "$k" in
            missing-lib) lib=elf-missing ;;
            dbus-off-path) dbus=/etc/dbus-1/session.d/org.librescrs.Agent.conf ;;
            bad-unit) unit=bad-unit ;;
            second-provider) extra=1 ;;
            no-conflicts) noconf=1 ;;
        esac
    done
    printf 'name liblibrescrs5\nfile /usr/lib/x/libLibreSCRS_Core.so.5 %s\nfile /usr/lib/x/pkcs11/librescrs-pkcs11.so elf\n' "$lib" >"$p/liblibrescrs5.$e"
    printf 'name librescrs-card-plugins\nfile /usr/lib/x/librescrs/plugins/eid.so elf\n' >"$p/librescrs-card-plugins.$e"
    printf 'name liblibrescrs-dev\nfile /usr/include/LibreSCRS/a.h text\n' >"$p/liblibrescrs-dev.$e"
    {
        echo 'name librescrs-pkcs11-direct'
        [ -n "$noconf" ] || echo 'conflicts librescrs-agent'
        echo 'module librescrs /usr/lib/x/pkcs11/librescrs-pkcs11.so'
    } >"$p/librescrs-pkcs11-direct.$e"
    [ "${STACK_DIRECT_ONLY:-}" = 1 ] && return
    printf 'name librescrs-agent\nconflicts librescrs-pkcs11-direct\nmodule librescrs-agent /usr/lib/x/pkcs11/librescrs-pkcs11-agent.so\nfile /usr/lib/x/pkcs11/librescrs-pkcs11-agent.so elf\nfile /usr/libexec/librescrs-agent elf\nfile /usr/lib/systemd/user/librescrs-agent.service %s\nfile %s text\nfile /usr/share/polkit-1/actions/org.librescrs.agent.configure.policy text\n' "$unit" "$dbus" >"$p/librescrs-agent.$e"
    printf 'name librescrs-pinentry-kde\nfile /usr/libexec/librescrs-pinentry-kde elf\n' >"$p/librescrs-pinentry-kde.$e"
    [ -z "$extra" ] || printf 'name librescrs-extra\nmodule librescrs-extra /usr/lib/x/pkcs11/extra.so\n' >"$p/librescrs-extra.$e"
}
verify() {  # verify <manager> [env...]
    local m="$1"; shift
    env PATH="$B:$PATH" STUB_ROOT="$work/root" STUB_STATE="$work/state" PKG_MANAGER="$m" PKG_SLUG=test \
        PKG_VERIFY_ROOT="$work/root" PKG_VERIFY_PKGS="$work/pkgs" PKG_VERIFY_REPORT="$work/report" "$@" \
        bash "$tool" >"$work/log" 2>&1
}

stack deb; verify apt; rc=$?
grep -q '^PASS S3 exactly one LibreSCRS module, and it is librescrs-agent' "$work/log"; s3=$?
grep -q '^PASS S7 direct-to-agent: exactly one registration afterwards (files 1, modules 1)' "$work/log"; s7=$?
expect "apt agent stack green, both switches measured" "0 0 0" "$rc $s3 $s7"
grep -q 'liblibrescrs-dev' "$work/state/liblibrescrs-dev" 2>/dev/null; test ! -e "$work/state/liblibrescrs-dev"
expect "development packages are not part of the user stack" 0 $?
stack rpm; verify dnf; expect "dnf agent stack green (bare install refuses, --allowerasing switches)" 0 $?
stack rpm; verify zypper; expect "zypper agent stack green (bare refuses, --force-resolution switches)" 0 $?
STACK_DIRECT_ONLY=1 stack deb; verify apt; rc=$?
grep -q '^PASS S3 exactly one LibreSCRS module, and it is librescrs ' "$work/log"; expect "a stack without the agent is the direct variant" "0 0" "$rc $?"

stack rpm; verify dnf STUB_BARE_SWITCHES=1
expect "dnf whose bare install switches contradicts the documented contract" 1 $?
stack rpm; verify zypper STUB_BARE_SWITCHES=1
expect "zypper whose bare install switches contradicts the documented contract" 1 $?
stack deb second-provider; verify apt; rc=$?
grep -q '^FAIL S3 ' "$work/log"; expect "two registered LibreSCRS providers are red" "1 0" "$rc $?"
stack deb no-conflicts; verify apt; rc=$?
grep -q '^FAIL S7 agent-to-direct: librescrs-pkcs11-direct installed, librescrs-agent removed' "$work/log"
expect "a provider that does not conflict leaves two registrations: red" "1 0" "$rc $?"
stack deb dbus-off-path; verify apt; rc=$?
grep -q '^FAIL S6 ' "$work/log"; expect "a D-Bus file off the daemon's path is red" "1 0" "$rc $?"
stack deb missing-lib; verify apt; rc=$?
grep -q '^FAIL S2 ' "$work/log"; expect "an unresolved shared library is red" "1 0" "$rc $?"
stack deb; verify apt STUB_P11TOOL=none; rc=$?
grep -q '^PASS S4 ' "$work/log"; expect "an empty slot list (exit 1, No slots.) is the no-card answer" "0 0" "$rc $?"
stack deb; verify apt STUB_P11TOOL=error; rc=$?
grep -q '^FAIL S4 ' "$work/log"; expect "a C_Initialize failure is red" "1 0" "$rc $?"
stack deb; verify apt STUB_P11TOOL=load; rc=$?
grep -q '^FAIL S4 ' "$work/log"; expect "a module that does not load is red" "1 0" "$rc $?"
stack deb bad-unit; verify apt; rc=$?
grep -q '^FAIL S5 ' "$work/log"; expect "a unit the verifier rejects is red" "1 0" "$rc $?"
stack deb; rm -rf "$work/pkgs"/0/*; verify apt; expect "no package at all is red" 1 $?

[ "$fail" -eq 0 ] || { echo "pkg-verify-inside.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
