#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-sign-inside.sh -- sign (MODE=sign) or only verify (MODE=verify) every
# /p/*.rpm against the package certificate, inside the distribution's image.
# Measured 2026-10-16: rpmsign is in rpm-sign on Fedora and in rpm on openSUSE;
# %{DSAHEADER:pgpsig} names the signing subkey's key ID on rpm 6.0.2 and 4.20.1
# alike (%{SIGPGP:pgpsig} is "(none)"); `rpm -K` exits 0 for an unsigned
# package and for one signed by a revoked subkey, so the exit code alone
# proves nothing -- the signature level is forced and the signer is named.
set -uo pipefail
: "${MODE:?}" "${PKG_MANAGER:?}" "${CERT:?}" "${SIGNER:?}"
case "$PKG_MANAGER" in
    dnf)    pk=(rpm-sign gnupg2) ;;
    zypper) pk=(rpm-build gpg2) ;;
    *) echo "pkg-sign: manager '$PKG_MANAGER'" >&2; exit 2 ;;
esac
[ "$MODE" = sign ] || pk=()
if [ "${#pk[@]}" -gt 0 ]; then
    if [ "$PKG_MANAGER" = dnf ]; then dnf -y -q install "${pk[@]}" >/dev/null
    else zypper -n -q install "${pk[@]}" >/dev/null; fi || exit 2
fi
GNUPGHOME="$(mktemp -d /var/tmp/lg.XXXXXX)"; export GNUPGHOME; chmod 700 "$GNUPGHOME"
db="$(mktemp -d /var/tmp/kdb.XXXXXX)"; trap 'rm -rf "$GNUPGHOME" "$db"' EXIT
rpmkeys --dbpath "$db" --import "$CERT" || { echo "pkg-sign: the certificate does not import" >&2; exit 2; }
if [ "$MODE" = sign ]; then
    gpg --batch --import "${SIGN_KEY:?}" 2>/dev/null || { echo "pkg-sign: the key does not import" >&2; exit 2; }
fi
want="${SIGNER,,}"; want="${want: -16}"
bad=0; shopt -s nullglob
for f in /p/*.rpm; do
    n="$(basename "$f")"
    if [ "$MODE" = sign ]; then
        rpmsign --define "_gpg_name ${SIGNER}!" --addsign "$f" >/dev/null 2>&1 \
            || { echo "::error::rpmsign failed on $n"; bad=1; continue; }
    fi
    out="$(rpmkeys --dbpath "$db" --define '_pkgverify_level signature' --checksig "$f" 2>&1)" \
        || { echo "::error::$n does not verify against the package certificate: $out"; bad=1; continue; }
    kid="$(rpm -qp --qf '%{DSAHEADER:pgpsig}\n' "$f" 2>/dev/null | grep -oiE '[0-9a-f]{16,40}' | tail -n 1)"
    kid="${kid,,}"; kid="${kid: -16}"
    [ "$kid" = "$want" ] || { echo "::error::$n is signed by ${kid:-nobody}, not $SIGNER"; bad=1; continue; }
    echo "verified  $n  ($SIGNER)"
done
exit "$bad"
