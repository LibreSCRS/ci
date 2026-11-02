#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (packages are built and judged in Linux containers)
# Self-test for pkg-verify-inside.sh outside a container: the package managers,
# p11-kit, ldd, pkcs11-tool and systemd-analyze are stubs over a fake root.
# A green stack passes for apt, dnf, zypper and pacman (Arch: lintian/rpmlint
# skipped by name, with the reason printed), and so does a stack below the
# agent that registers no module; two registered providers, a module
# registered below the agent, a D-Bus file off the daemon's path, an
# unresolved library, a failing pkcs11-tool and a unit the verifier rejects
# are each red.
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
# A fake package is a text file: "name N", "file PATH KIND"
# (KIND: elf | elf-missing | text | bad-unit), "module NAME PATH".
cat >"$B/stubpm" <<'EOF'
#!/usr/bin/env bash
# stubpm <manager> <args...>: install fake package files into STUB_ROOT.
mgr="$1"; shift
S="$STUB_STATE"; R="$STUB_ROOT"; mkdir -p "$S"
files=()
for a in "$@"; do
  case "$a" in -*) ;; *) [ -f "$a" ] && files+=("$a") ;; esac
done
[ "${#files[@]}" -gt 0 ] || exit 0          # distribution tools: always "installed"
field() { sed -n "s/^$1 //p" "$2"; }
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
cat >"$B/zypper" <<'XEOF'
#!/usr/bin/env bash
[ "$1" = -n ] && [ "$2" = -q ] && [ "$3" = refresh ] && exit 0
exec stubpm zypper "$@"
XEOF
printf '#!/usr/bin/env bash\nexec stubpm dnf "$@"\n' >"$B/dnf"
cat >"$B/pacman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -Syu) exit 0 ;;
  -Qqp) sed -n 's/^name //p' "${!#}" ;;
  -Qlq) [ -f "$STUB_STATE/$2" ] && cat "$STUB_STATE/$2" ;;
  -Q)   [ -f "$STUB_STATE/$2" ] ;;
  *)    exec stubpm pacman "$@" ;;
esac
EOF
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
cat >"$B/file" <<'XEOF'
#!/usr/bin/env bash
if grep -q "^ELF" "${!#}"; then echo "ELF 64-bit LSB shared object"; else echo "ASCII text"; fi
XEOF
cat >"$B/ldd" <<'XEOF'
#!/usr/bin/env bash
if grep -q MISSING "$1"; then printf '\tlibgone.so.1 => not found\n'; fi
exit 0
XEOF
cat >"$B/pkcs11-tool" <<'XEOF'
#!/usr/bin/env bash
case "${STUB_P11TOOL:-slots}" in
  slots) echo "Available slots:"; echo "Slot 0 (0x0): reader"; exit 0 ;;
  none)  echo "Available slots:"; echo "No slots."; exit 1 ;;
  error) echo "error: PKCS11 function C_Initialize failed: rv = CKR_GENERAL_ERROR (0x5)"; exit 1 ;;
  load)  echo "Available slots:"; echo "error: cannot load module"; exit 1 ;;
esac
XEOF
cat >"$B/systemd-analyze" <<'XEOF'
#!/usr/bin/env bash
# like the real one: --user without a runtime directory verifies nothing
[ "$1" = --user ] && [ ! -d "${XDG_RUNTIME_DIR:-/nonexistent}" ] && { echo "Failed to initialize manager: No such device or address"; exit 1; }
grep -q BAD "${!#}" && { echo "$(basename "${!#}"): Command /usr/libexec/librescrs-agent is not executable"; exit 1; }
exit 0
XEOF
cat >"$B/lintian" <<'XEOF'
#!/usr/bin/env bash
for a in "$@"; do if [ -f "$a" ]; then basename "$a"; fi; done >"$STUB_LINT_ARGS"
exit 0
XEOF
cp "$B/lintian" "$B/rpmlint"
printf '#!/bin/sh\nexit 0\n' >"$B/timeout.real"
cat >"$B/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
chmod +x "$B"/*

# the consumer's hook (S9), used by the Arch case and the S9 cases
cat >"$work/hook.sh" <<'HOOK'
#!/usr/bin/env bash
echo "PASS hook saw FAMILY=$FAMILY"
exit "${HOOK_RC:-0}"
HOOK

# ── the stack ─────────────────────────────────────────────────────────────
stack() {  # stack <ext> [extra-kind...]: write the fake packages
    local e="$1" p="$work/pkgs/0"; shift
    rm -rf "$work/pkgs" "$work/root" "$work/state" "$work/report"; mkdir -p "$p" "$work/root" "$work/report"
    local lmmod="" lib=elf dbus=/usr/share/dbus-1/services/org.librescrs.Agent.service unit=text extra=""
    for k in "$@"; do
        case "$k" in
            missing-lib) lib=elf-missing ;;
            dbus-off-path) dbus=/etc/dbus-1/session.d/org.librescrs.Agent.conf ;;
            bad-unit) unit=bad-unit ;;
            second-provider) extra=1 ;;
            middleware-module) lmmod=1 ;;
        esac
    done
    printf 'name liblibrescrs5\nfile /usr/lib/x/libLibreSCRS_Core.so.5 %s\n' "$lib" >"$p/liblibrescrs5.$e"
    [ -z "$lmmod" ] || printf 'file /usr/lib/x/pkcs11/librescrs-pkcs11.so elf\nmodule librescrs /usr/lib/x/pkcs11/librescrs-pkcs11.so\n' >>"$p/liblibrescrs5.$e"
    printf 'name librescrs-card-plugins\nfile /usr/lib/x/librescrs/plugins/eid.so elf\n' >"$p/librescrs-card-plugins.$e"
    printf 'name liblibrescrs-dev\nfile /usr/include/LibreSCRS/a.h text\n' >"$p/liblibrescrs-dev.$e"
    [ "${STACK_BELOW_AGENT:-}" = 1 ] && return
    printf 'name librescrs-agent\nmodule librescrs-agent /usr/lib/x/pkcs11/librescrs-pkcs11-agent.so\nfile /usr/lib/x/pkcs11/librescrs-pkcs11-agent.so elf\nfile /usr/libexec/librescrs-agent elf\nfile /usr/lib/systemd/user/librescrs-agent.service %s\nfile %s text\nfile /usr/share/polkit-1/actions/org.librescrs.agent.configure.policy text\n' "$unit" "$dbus" >"$p/librescrs-agent.$e"
    printf 'name librescrs-pinentry-kde\nfile /usr/libexec/librescrs-pinentry-kde elf\n' >"$p/librescrs-pinentry-kde.$e"
    [ -z "$extra" ] || printf 'name librescrs-extra\nmodule librescrs-extra /usr/lib/x/pkcs11/extra.so\n' >"$p/librescrs-extra.$e"
}
verify() {  # verify <manager> [env...]
    local m="$1"; shift
    env PATH="$B:$PATH" STUB_LINT_ARGS="$work/lint-args" STUB_ROOT="$work/root" STUB_STATE="$work/state" PKG_MANAGER="$m" PKG_SLUG=test \
        PKG_VERIFY_ROOT="$work/root" PKG_VERIFY_PKGS="$work/pkgs" PKG_VERIFY_REPORT="$work/report" "$@" \
        bash "$tool" >"$work/log" 2>&1
}

stack deb; verify apt; rc=$?
grep -q '^PASS S3 exactly one LibreSCRS module, and it is librescrs-agent' "$work/log"
expect "apt agent stack green, the agent's module is the one registered" "0 0" "$rc $?"
grep -q 'liblibrescrs-dev' "$work/state/liblibrescrs-dev" 2>/dev/null; test ! -e "$work/state/liblibrescrs-dev"
expect "development packages are not part of the user stack" 0 $?
stack rpm; mkdir -p "$work/repos"; printf '[fedora-cisco-openh264]\nenabled=1\n' >"$work/repos/fedora-cisco-openh264.repo"
verify dnf PKG_DNF_REPO_DIR="$work/repos"; rc=$?
grep -qx 'enabled=0' "$work/repos/fedora-cisco-openh264.repo"
expect "dnf agent stack green, openh264 repo off" "0 0" "$rc $?"
stack rpm; verify zypper; expect "zypper agent stack green" 0 $?
stack pkg.tar.zst; verify pacman PKG_VERIFY_HOOK="$work/hook.sh"; rc=$?
grep -q '^PASS S3 exactly one LibreSCRS module, and it is librescrs-agent' "$work/log" \
  && grep -q '^SKIP S7 lintian/rpmlint: .* -- ' "$work/log" && ! grep -q '^PASS S7 ' "$work/log" \
  && [ ! -s "$work/report/linted.txt" ] && grep -q '^PASS hook saw FAMILY=arch' "$work/log"
expect "pacman agent stack green, S7 skipped by name with its reason, the hook sees FAMILY=arch" "0 0" "$rc $?"
# a real run lints its own packages (the action's lint: own), so the lint
# scope is there: S7 is still the one SKIP line, not a PASS beside it
stack pkg.tar.zst; printf 'librescrs-agent.pkg.tar.zst\nlibrescrs-pinentry-kde.pkg.tar.zst\n' >"$work/report/lint-files.txt"
verify pacman; rc=$?
test "$(grep -E '^[A-Z]+ +S7 ' "$work/log" | cut -c1-12)" = "SKIP S7 lint"
expect "pacman with a lint scope: S7 is only the SKIP line" "0 0" "$rc $?"
stack pkg.tar.zst missing-lib; verify pacman; rc=$?
grep -q '^FAIL S2 ' "$work/log"; expect "pacman: an unresolved shared library is red" "1 0" "$rc $?"
STACK_BELOW_AGENT=1 stack pkg.tar.zst middleware-module; verify pacman; rc=$?
grep -q '^FAIL S3 no LibreSCRS module registered below the agent (counted 1)' "$work/log"
expect "pacman: a module the middleware registers on its own is red" "1 0" "$rc $?"
stack deb; verify apt; rc=$?; grep -q '^SKIP S7' "$work/log"
expect "deb/rpm never skip lint" "0 1" "$rc $?"
STACK_BELOW_AGENT=1 stack deb; verify apt; rc=$?
grep -q '^PASS S3 no LibreSCRS module registered below the agent (counted 0)' "$work/log"
expect "a stack below the agent registers no module" "0 0" "$rc $?"
STACK_BELOW_AGENT=1 stack deb middleware-module; verify apt; rc=$?
grep -q '^FAIL S3 no LibreSCRS module registered below the agent (counted 1)' "$work/log"
expect "a module the middleware registers on its own is red" "1 0" "$rc $?"
stack deb middleware-module; verify apt; rc=$?
grep -q '^FAIL S3 exactly one LibreSCRS module, and it is librescrs-agent (counted 2)' "$work/log"
expect "a middleware module beside the agent's is red" "1 0" "$rc $?"

stack deb second-provider; verify apt; rc=$?
grep -q '^FAIL S3 ' "$work/log"; expect "two registered LibreSCRS providers are red" "1 0" "$rc $?"
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

# lint scope: only the files named in lint-files.txt are linted and judged
stack deb; printf 'librescrs-agent.deb\nlibrescrs-pinentry-kde.deb\n' >"$work/report/lint-files.txt"
verify apt; rc=$?
test "$(sort "$work/lint-args" | tr '\n' ' ')" = "librescrs-agent.deb librescrs-pinentry-kde.deb "; args=$?
test "$(sort "$work/report/linted.txt" | tr '\n' ' ')" = "librescrs-agent librescrs-pinentry-kde "; names=$?
expect "a lint scope lints and reports only the consumer's packages" "0 0 0" "$rc $args $names"
stack deb; verify apt; rc=$?
grep -qx 'liblibrescrs5.deb' "$work/lint-args"; expect "without a scope every package is linted" "0 0" "$rc $?"
stack deb; printf 'librescrs-agent.deb\nlibrescrs-gone.deb\n' >"$work/report/lint-files.txt"
verify apt; rc=$?
grep -q '^FAIL S7 every package named for linting is present' "$work/log"; expect "a scope naming a package that is not there is red" "1 0" "$rc $?"

# S9: the consumer's hook runs last, in the same run, with FAMILY set, and its
# exit status is the verdict.
rm -f "$work/report/lint-files.txt"
stack deb; verify apt PKG_VERIFY_HOOK="$work/hook.sh"; rc=$?
grep -q '^PASS hook saw FAMILY=deb' "$work/log" && grep -q '^PASS S9 ' "$work/log"
expect "the repository hook runs in the same run and passes" "0 0" "$rc $?"
tail -n 3 "$work/log" | grep -q '^PASS S9 '; expect "the hook runs after every stack check" 0 $?
stack deb; verify apt PKG_VERIFY_HOOK="$work/hook.sh" HOOK_RC=1; rc=$?
grep -q '^FAIL S9 ' "$work/log"; expect "a failing hook is red" "1 0" "$rc $?"
stack deb; verify apt; rc=$?; grep -q "S9 " "$work/log"; expect "no hook: green, and no S9 line" "0 1" "$rc $?"

[ "$fail" -eq 0 ] || { echo "pkg-verify-inside.selftest: FAILED"; exit 1; }
echo "selftest: $cases cases, $red red-proved"
