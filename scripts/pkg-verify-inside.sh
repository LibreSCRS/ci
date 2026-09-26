#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-verify-inside.sh -- runs INSIDE a clean container of the slug's image
# (started by pkg-verify.sh) with every package of the stack under /pkgs/*/.
# Asserts what the packages leave on a machine a user installs them on.
#
#   S1  the user stack installs (runtime packages; development packages and
#       the provider the chosen variant excludes are left out)
#   S2  nothing of ours links against a library that is not there (ldd)
#   S3  p11-kit lists EXACTLY ONE LibreSCRS module, and it is the variant's
#   S4  pkcs11-tool --list-slots over that module succeeds with no card
#   S5  systemd-analyze verify accepts every unit we install
#   S6  every D-Bus and polkit file of ours is on a path the daemons read
#   S7  the direct <-> agent switch behaves as the documented contract for
#       this package manager (both the documented command and the bare one)
#   S8  lintian / rpmlint over the packages this run judges (all of them, or
#       only the file names listed in /report/lint-files.txt -- the
#       consumer's own; upstream packages are linted in their own
#       repository); judged on the host by pkg-lint-accept.py
#   S9  a third provider (the distribution's OpenSC) is MEASURED, not judged
#
# Variant: "agent" when librescrs-agent is among the packages, else "direct"
# when librescrs-pkcs11-direct is, else "none" (a stack below both providers).
#
# Environment: PKG_MANAGER (apt|dnf|zypper), PKG_SLUG. Exit 0 / 1.
# shellcheck disable=SC2319  # "assert; read its status" is the pattern here, on purpose
set -uo pipefail
# Never `producer | grep -q` here: grep -q exits at the first match, the
# producer takes SIGPIPE, and under pipefail a true match reads as a failure.
fail=0
# check <message> <status>. A $(...) in the message runs before the status
# argument is expanded and resets $?, so such a caller passes a saved status.
check() { if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
info() { echo "INFO $*"; }
# The self-test runs this outside a container: R prefixes every path the
# packages install to, PKGS and REPORT move the two mounts. In a container
# all three keep their defaults.
R="${PKG_VERIFY_ROOT:-}"
PKGS="${PKG_VERIFY_PKGS:-/pkgs}"
REPORT="${PKG_VERIFY_REPORT:-/report}"
mkdir -p "$REPORT"

MANAGER="${PKG_MANAGER:?}"
case "$MANAGER" in
apt)
    export DEBIAN_FRONTEND=noninteractive
    # Ubuntu's image excludes translations from every install; that measures
    # the image, not the package.
    rm -f /etc/dpkg/dpkg.cfg.d/excludes
    apt-get update -qq
    pm_tools() { apt-get install -y -qq --no-install-recommends "$@" >/dev/null; }
    pm_files() { apt-get install -y --no-install-recommends "$@"; }
    is_installed() { [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]]; }
    files_of() { dpkg -L "$1" 2>/dev/null; }
    name_of() { dpkg-deb -f "$1" Package; }
    EXT=deb
    ;;
dnf)
    pm_tools() { dnf -y -q install "$@" >/dev/null; }
    pm_files() { dnf -y install "$@"; }
    is_installed() { rpm -q "$1" >/dev/null 2>&1; }
    files_of() { rpm -ql "$1" 2>/dev/null; }
    name_of() { rpm -qp --qf '%{NAME}' "$1" 2>/dev/null; }
    EXT=rpm
    ;;
zypper)
    zypper -n -q refresh >/dev/null
    pm_tools() { zypper -n -q install "$@" >/dev/null; }
    pm_files() { zypper -n --no-gpg-checks install --allow-unsigned-rpm "$@"; }
    is_installed() { rpm -q "$1" >/dev/null 2>&1; }
    files_of() { rpm -ql "$1" 2>/dev/null; }
    name_of() { rpm -qp --qf '%{NAME}' "$1" 2>/dev/null; }
    EXT=rpm
    ;;
*) echo "FAIL unknown manager $MANAGER"; exit 1 ;;
esac

# The distribution tools the checks use. p11-kit is what a desktop has; the
# rest are the measuring instruments.
case "$MANAGER" in
    apt) pm_tools p11-kit file binutils systemd dbus-daemon dbus-user-session ;;
    dnf) pm_tools p11-kit p11-kit-trust file binutils systemd dbus-daemon ;;
    zypper) pm_tools p11-kit p11-kit-tools file binutils findutils systemd dbus-1-daemon ;;
esac

mapfile -t ALL < <(find "$PKGS" -type f -name "*.$EXT" | sort)
[ "${#ALL[@]}" -gt 0 ] || { echo "FAIL no .$EXT package under $PKGS"; exit 1; }
declare -A FILE=()
for f in "${ALL[@]}"; do FILE[$(name_of "$f")]="$f"; done
info "packages: ${!FILE[*]}"
is_dev() { case "$1" in *-dev|*-devel) return 0 ;; esac; return 1; }

variant=none
[ -n "${FILE[librescrs-pkcs11-direct]+x}" ] && variant=direct
[ -n "${FILE[librescrs-agent]+x}" ] && variant=agent
info "variant: $variant"

stack=()
for n in "${!FILE[@]}"; do
    is_dev "$n" && continue
    [ "$variant" = agent ] && [ "$n" = librescrs-pkcs11-direct ] && continue
    stack+=("${FILE[$n]}")
done

# ── S1 ────────────────────────────────────────────────────────────────────
pm_files "${stack[@]}" >"$REPORT/install.txt" 2>&1
check "S1 the $variant user stack installs (${#stack[@]} packages)" $?
ours=()
for n in "${!FILE[@]}"; do is_installed "$n" && ours+=("$n"); done
info "installed of ours: ${ours[*]}"

# ── S2 ────────────────────────────────────────────────────────────────────
nelf=0; miss=0
while IFS= read -r f; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [[ "$(file -b "$f")" == ELF* ]] || continue
    nelf=$((nelf + 1))
    l="$(ldd "$f" 2>&1)"
    if [[ "$l" == *'not found'* ]]; then echo "  unresolved in $f:"; grep 'not found' <<<"$l"; miss=1; fi
done < <(for n in "${ours[@]}"; do files_of "$n"; done | sort -u)
test "$nelf" -gt 0 -a "$miss" -eq 0
check "S2 no unresolved shared-library dependency ($nelf ELF files)" $?

# ── S3 / S4 ───────────────────────────────────────────────────────────────
modules() { p11-kit list-modules 2>/dev/null | grep -c '^module: librescrs'; }
module_path() {  # the module file p11-kit resolves for our registration
    p11-kit list-modules 2>/dev/null | awk '/^module: librescrs/{m=1; next} /^module: /{m=0} m && /^[[:space:]]+path:/{print $2; exit}'
}
case "$variant" in
    agent)  want=librescrs-agent ;;
    direct) want=librescrs ;;
    *)      want="" ;;
esac
n=$(modules)
if [ -n "$want" ]; then
    test "$n" -eq 1 && grep -qx "module: $want" <<<"$(p11-kit list-modules 2>/dev/null)"
    check "S3 exactly one LibreSCRS module, and it is $want (counted $n)" $?
    p11-kit list-modules | grep -A3 '^module: librescrs' | sed 's/^/     /'
    pm_tools opensc >/dev/null 2>&1 || true
    if command -v pkcs11-tool >/dev/null 2>&1; then
        mp="$(module_path)"
        [ -n "$mp" ] && [ -e "$mp" ] || mp="$(find "$R"/usr/lib* -path "*pkcs11/$( [ "$variant" = agent ] && echo librescrs-pkcs11-agent || echo librescrs-pkcs11).so" | head -n 1)"
        timeout 60 pkcs11-tool --module "$mp" --list-slots >"$REPORT/list-slots.txt" 2>&1
        rc=$?
        # pkcs11-tool exits 1 when the slot list is empty, which is exactly
        # the no-card, no-reader state here. What must hold is that the module
        # loaded and C_GetSlotList answered: the listing header is printed, and
        # no PKCS#11 error or load failure is.
        ok=1
        if grep -q '^Available slots:' "$REPORT/list-slots.txt" \
           && ! grep -qiE 'CKR_|error|failed|cannot|not found' "$REPORT/list-slots.txt"; then
            case "$rc" in 0) ok=0 ;; 1) grep -q '^No slots\.' "$REPORT/list-slots.txt" && ok=0 ;; esac
        fi
        check "S4 pkcs11-tool --list-slots over $mp answers with no card (rc=$rc)" "$ok"
        sed 's/^/     /' "$REPORT/list-slots.txt" | head -n 10
        # S9: the distribution's OpenSC registers its own module beside ours.
        info "S9 providers with the distribution OpenSC installed: $(p11-kit list-modules | grep -c '^module: ') ($(p11-kit list-modules | sed -n 's/^module: //p' | tr '\n' ' '))"
    else
        check "S4 pkcs11-tool is available from the distribution's opensc package" 1
    fi
else
    test "$n" -eq 0; check "S3 no LibreSCRS module registered below both providers (counted $n)" $?
fi

# ── S5 ────────────────────────────────────────────────────────────────────
# The offline verifier needs a runtime directory for --user (without one it
# prints "Failed to initialize manager" and verifies nothing -- a message a
# filter would wave through), and the units' own dependencies (dbus.socket of
# the user bus) installed. Then its exit code is the verdict.
mapfile -t units < <(for n in "${ours[@]}"; do files_of "$n"; done | grep -E '/systemd/(user|system)/[^/]+\.(service|socket|timer)$' | sort -u)
if [ "${#units[@]}" -gt 0 ]; then
    XDG_RUNTIME_DIR="$(mktemp -d)"; export XDG_RUNTIME_DIR
    for u in "${units[@]}"; do
        case "$u" in */systemd/user/*) scope=--user ;; *) scope=--system ;; esac
        v="$REPORT/verify-$(basename "$u").txt"
        systemd-analyze "$scope" verify --man=no "$u" >"$v" 2>&1; rc=$?
        check "S5 systemd-analyze $scope verify $(basename "$u") (rc=$rc)" "$rc"
        [ "$rc" -eq 0 ] || sed 's/^/     /' "$v"
    done
else
    info "S5 no systemd unit in this stack"
fi

# ── S6 ────────────────────────────────────────────────────────────────────
mapfile -t bus < <(for n in "${ours[@]}"; do files_of "$n"; done | grep -E '/(dbus-1|polkit-1)/' | while read -r f; do [ -d "$f" ] || echo "$f"; done | sort -u)
if [ "${#bus[@]}" -gt 0 ]; then
    wrong=0
    for f in "${bus[@]}"; do
        case "$f" in
            "$R"/usr/share/dbus-1/services/*.service|"$R"/usr/share/dbus-1/system-services/*.service) ;;
            "$R"/usr/share/dbus-1/session.d/*.conf|"$R"/usr/share/dbus-1/system.d/*.conf) ;;
            "$R"/usr/share/dbus-1/interfaces/*.xml) ;;
            "$R"/usr/share/polkit-1/actions/*.policy|"$R"/usr/share/polkit-1/rules.d/*.rules) ;;
            *) echo "     off the daemons' paths: $f"; wrong=1 ;;
        esac
    done
    check "S6 every D-Bus / polkit file of ours on a path the daemon reads (${#bus[@]} files)" "$wrong"
    [ "$variant" != agent ] || {
        compgen -G "$R/usr/share/dbus-1/services/org.librescrs.*.service" >/dev/null \
            && compgen -G "$R/usr/share/polkit-1/actions/org.librescrs.*.policy" >/dev/null
        check "S6 the agent's D-Bus activation file and polkit action are installed" $?
    }
else
    info "S6 no D-Bus or polkit file in this stack"
fi

# ── S7 ────────────────────────────────────────────────────────────────────
# The contract a user is told, per package manager (published on the site and
# in the package descriptions -- keep all three the same):
#   apt     `apt install ./<other>.deb` switches: the installed provider is
#           removed (Conflicts), no flag needed.
#   dnf     `dnf install <other>.rpm` REFUSES (conflict); the switch is
#           `dnf install --allowerasing <other>.rpm`.
#   zypper  `zypper install <other>.rpm` REFUSES non-interactively (conflict);
#           the switch is `zypper install --force-resolution <other>.rpm`.
# Both halves are asserted: the documented command switches, and the bare
# command does what the documentation says it does.
registrations() { local f n=0; for f in "$R"/usr/share/p11-kit/modules/librescrs*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
switch_to() {  # switch_to <label> <to-pkg> <from-pkg>
    local label="$1" to="$2" from="$3" f="${FILE[$2]}" rc
    if ! { is_installed "$from" && ! is_installed "$to"; }; then
        check "S7 $label precondition: $from installed, $to not" 1; return
    fi
    case "$MANAGER" in
    apt)
        apt-get install -y --no-install-recommends "$f" >"$REPORT/s7-$label.txt" 2>&1; rc=$?
        check "S7 $label: apt install switches (rc=$rc)" "$rc"
        ;;
    dnf)
        dnf -y install "$f" >"$REPORT/s7-$label-bare.txt" 2>&1; rc=$?
        test "$rc" -ne 0 && is_installed "$from" && ! is_installed "$to"
        check "S7 $label: bare dnf install refuses and changes nothing (rc=$rc)" $?
        dnf -y install --allowerasing "$f" >"$REPORT/s7-$label.txt" 2>&1; rc=$?
        check "S7 $label: dnf install --allowerasing switches (rc=$rc)" "$rc"
        ;;
    zypper)
        zypper -n --no-gpg-checks install --allow-unsigned-rpm "$f" >"$REPORT/s7-$label-bare.txt" 2>&1; rc=$?
        test "$rc" -ne 0 && is_installed "$from" && ! is_installed "$to"
        check "S7 $label: bare zypper install refuses and changes nothing (rc=$rc)" $?
        zypper -n --no-gpg-checks install --allow-unsigned-rpm --force-resolution "$f" >"$REPORT/s7-$label.txt" 2>&1; rc=$?
        check "S7 $label: zypper install --force-resolution switches (rc=$rc)" "$rc"
        ;;
    esac
    is_installed "$to" && ! is_installed "$from"
    check "S7 $label: $to installed, $from removed" $?
    local nreg nmod
    nreg="$(registrations)"; nmod="$(modules)"
    test "$nreg" -eq 1 && test "$nmod" -eq 1
    check "S7 $label: exactly one registration afterwards (files $nreg, modules $nmod)" $?
}
if [ -n "${FILE[librescrs-pkcs11-direct]+x}" ] && [ -n "${FILE[librescrs-agent]+x}" ]; then
    switch_to agent-to-direct librescrs-pkcs11-direct librescrs-agent
    switch_to direct-to-agent librescrs-agent librescrs-pkcs11-direct
else
    info "S7 not applicable: this stack does not carry both providers"
fi

# ── S8 ────────────────────────────────────────────────────────────────────
: >"$REPORT/linted.txt"
LINT=()
if [ -f "$REPORT/lint-files.txt" ]; then
    declare -A want=()
    while IFS= read -r b; do [ -n "$b" ] && want[$b]=1; done <"$REPORT/lint-files.txt"
    for f in "${ALL[@]}"; do [ -n "${want[$(basename "$f")]+x}" ] && LINT+=("$f"); done
    test "${#LINT[@]}" -eq "${#want[@]}" -a "${#LINT[@]}" -gt 0
    check "S8 every package named for linting is present (${#LINT[@]} of ${#want[@]})" $?
else
    LINT=("${ALL[@]}")
fi
for f in "${LINT[@]}"; do name_of "$f" >>"$REPORT/linted.txt"; done
info "S8 linting: $(for f in "${LINT[@]}"; do basename "$f"; done | tr '\n' ' ')"
if [ "$EXT" = deb ]; then
    pm_tools lintian
    command -v lintian >/dev/null 2>&1; check "S8 lintian is installed" $?
    # One tag is suppressed here rather than accepted per package:
    # initial-upload-closes-no-bugs asks a first Debian ARCHIVE upload to close
    # its ITP bug. These packages are published as release files, not uploaded
    # to Debian, so the tag describes a process that does not happen.
    lintian --no-tag-display-limit --display-level '>=warning' \
        --suppress-tags initial-upload-closes-no-bugs "${LINT[@]}" >"$REPORT/lintian.txt" 2>&1
    echo "     lintian rc=$? ($(grep -cE '^[EW]: ' "$REPORT/lintian.txt") E/W lines)"
else
    pm_tools rpmlint
    command -v rpmlint >/dev/null 2>&1; check "S8 rpmlint is installed" $?
    rpmlint "${LINT[@]}" >"$REPORT/rpmlint.txt" 2>&1
    echo "     rpmlint rc=$? ($(grep -cE ': [EW]: ' "$REPORT/rpmlint.txt") E/W lines)"
fi

echo "== pkg-verify-inside $PKG_SLUG ($variant): $([ $fail -eq 0 ] && echo GREEN || echo RED)"
exit $fail
