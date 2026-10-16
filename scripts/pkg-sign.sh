#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-sign.sh -- sign every *.rpm in a directory inside its own distribution's
# image, and verify each one strictly against the key set's certificate.
#
# Usage: pkg-sign.sh --dir <d> --keyset <rehearsal|package-signing>
#                    [--key <armored secret subkey>] [--verify-only]
#
# The slug comes from the asset name, <stem>.<slug>.rpm, and names the image
# (pkg-images get <slug>) that pkg-sign-inside.sh runs in: each rpm is signed
# and judged by the rpm its distribution ships. .deb and every other file are
# never touched -- apt trusts the signed index, not the package.
#
# --keyset names keys/<keyset>.env (four fingerprints) and keys/<keyset>.asc
# (the certificate the packages are judged against). The rpms are signed by
# S_RPM_FPR, and a signature by any other key or subkey is red.
#   rehearsal        the secret part is keys/rehearsal.sec.asc -- public on
#                    purpose, never trusted; --key is refused
#   package-signing  the secret subkey is --key (needed unless --verify-only)
# --verify-only imports no secret key and installs no signing tool.
#
# The packages are judged in a staging copy, one per slug, and in sign mode
# copied back only when every rpm of that slug verified; files a container
# wrote are handed back to the caller's uid through the same image.
#
# Environment: PKG_DOCKER, PKG_DOCKER_NETWORK as pkg-gate.sh.
#
# Exit codes: 0 every rpm verified, 1 one did not (or did not sign), 2 cannot
# judge (bad usage, unknown key set or slug, no rpm, docker missing, a key or
# certificate that does not import).
set -uo pipefail

here="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)" || exit 2
keys="$(cd -- "$here/../keys" 2>/dev/null && pwd)" || { echo "pkg-sign: no keys/ next to $here -- cannot judge" >&2; exit 2; }
die2() { echo "pkg-sign: $* -- cannot judge" >&2; exit 2; }

DIR="" KEYSET="" KEY="" VERIFY_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)         [ $# -ge 2 ] || die2 "--dir needs a value"; DIR="$2"; shift 2 ;;
        --keyset)      [ $# -ge 2 ] || die2 "--keyset needs a value"; KEYSET="$2"; shift 2 ;;
        --key)         [ $# -ge 2 ] || die2 "--key needs a value"; KEY="$2"; shift 2 ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        *) die2 "usage: $(basename -- "$0") --dir D --keyset rehearsal|package-signing [--key FILE] [--verify-only]" ;;
    esac
done
[ -n "$DIR" ] && [ -d "$DIR" ] || die2 "--dir '$DIR' is not a directory"
DIR="$(cd -- "$DIR" && pwd)"

case "$KEYSET" in
    rehearsal)
        [ -z "$KEY" ] || die2 "a rehearsal signs with keys/rehearsal.sec.asc, never with --key"
        KEY="$keys/rehearsal.sec.asc" ;;
    package-signing)
        [ "$VERIFY_ONLY" = 1 ] || [ -n "$KEY" ] || die2 "--keyset package-signing needs --key" ;;
    *) die2 "unknown key set '$KEYSET'" ;;
esac
[ "$VERIFY_ONLY" = 1 ] || [ -s "$KEY" ] || die2 "no secret key at '$KEY'"
env_file="$keys/$KEYSET.env" cert="$keys/$KEYSET.asc"
[ -f "$env_file" ] || die2 "no $env_file"
[ -s "$cert" ] || die2 "no certificate $cert"

# The env file is data, never sourced: exactly four rows, in this order.
want=(PACKAGE_FPR S_RPM_FPR S_IDX_FPR S_REZ_FPR)
mapfile -t rows <"$env_file"
[ "${#rows[@]}" -eq 4 ] || die2 "$env_file has ${#rows[@]} rows, not 4"
declare -A fpr=()
for i in 0 1 2 3; do
    [[ "${rows[$i]}" =~ ^${want[$i]}=([0-9A-F]{40})$ ]] || die2 "$env_file row $((i + 1)) is not ${want[$i]}=<40 HEX>"
    fpr[${want[$i]}]="${BASH_REMATCH[1]}"
done
SIGNER="${fpr[S_RPM_FPR]}"

DOCKER="${PKG_DOCKER:-docker}"
command -v "$DOCKER" >/dev/null 2>&1 || die2 "$DOCKER is not on PATH"
NET=()
[ -z "${PKG_DOCKER_NETWORK:-}" ] || NET=(--network "$PKG_DOCKER_NETWORK")

# Group the rpms by slug; an unknown slug or a non-rpm one cannot be judged.
declare -A group=() image=() manager=()
shopt -s nullglob
for f in "$DIR"/*.rpm; do
    n="$(basename "$f")"; s="${n%.rpm}"; s="${s##*.}"
    if [ -z "${image[$s]:-}" ]; then
        [ "$("$here/pkg-images" family "$s" 2>/dev/null)" = rpm ] || die2 "$n: '$s' is not an rpm slug"
        image[$s]="$("$here/pkg-images" get "$s")" || die2 "$n: no image for '$s'"
        manager[$s]="$("$here/pkg-images" manager "$s")" || die2 "$n: no manager for '$s'"
    fi
    group[$s]+="$n"$'\n'
done
[ "${#group[@]}" -gt 0 ] || die2 "no *.rpm in $DIR"

root="$(mktemp -d "${TMPDIR:-/var/tmp}/ps.XXXXXX")" || die2 "no temporary directory"
last_image=""
# Every container is named after this run, so a run that is killed mid-way
# still removes the one holding the imported key.
cname="pkg-sign-$$"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    "$DOCKER" ps -aq --filter "name=^$cname-" | xargs -r "$DOCKER" rm -f >/dev/null 2>&1
    rm -rf "$root" 2>/dev/null \
        || { [ -n "$last_image" ] && "$DOCKER" run --rm -v "$root:/w" "$last_image" rm -rf /w/s >/dev/null 2>&1; rm -rf "$root"; }
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM   # a signal still runs the EXIT trap
k="$root/k"; mkdir -p "$k" "$root/s"; chmod 700 "$k"
command cp -f "$cert" "$k/cert.asc"
keyenv=()
if [ "$VERIFY_ONLY" = 0 ]; then
    (umask 077; command cp -f "$KEY" "$k/key.asc") || die2 "cannot stage the secret key"
    keyenv=(-e SIGN_KEY=/k/key.asc)
    MODE=sign
else
    MODE=verify
fi
own="$(id -u):$(id -g)"

verdict=0
for s in $(printf '%s\n' "${!group[@]}" | sort); do
    st="$root/s/$s"; mkdir -p "$st"
    mapfile -t names < <(printf '%s' "${group[$s]}")
    for n in "${names[@]}"; do command cp -f "$DIR/$n" "$st/$n"; done
    echo "-- $s: $MODE ${#names[@]} rpm in ${image[$s]}"
    last_image="${image[$s]}"
    # In the background and waited for, so a signal reaches the trap at once
    # instead of after the container finishes.
    "$DOCKER" run --rm --name "$cname-$s" "${NET[@]}" -v "$st:/p" -v "$k:/k:ro" -v "$here:/ci-scripts:ro" \
        -e "MODE=$MODE" -e "PKG_MANAGER=${manager[$s]}" -e CERT=/k/cert.asc -e "SIGNER=$SIGNER" "${keyenv[@]}" \
        "${image[$s]}" bash /ci-scripts/pkg-sign-inside.sh &
    wait "$!"
    rc=$?
    "$DOCKER" run --rm --name "$cname-$s-chown" -v "$st:/p" "${image[$s]}" chown -R "$own" /p >/dev/null 2>&1 \
        || { echo "pkg-sign: cannot hand $s's packages back to $own" >&2; rc=2; }
    case "$rc" in
        0) if [ "$MODE" = sign ]; then
               for n in "${names[@]}"; do command cp -f "$st/$n" "$DIR/$n" || rc=2; done
           fi ;;
        1) ;;
        *) rc=2 ;;
    esac
    rm -rf "$st"
    if [ "$rc" -eq 2 ]; then verdict=2; elif [ "$rc" -eq 1 ] && [ "$verdict" -eq 0 ]; then verdict=1; fi
done
exit "$verdict"
