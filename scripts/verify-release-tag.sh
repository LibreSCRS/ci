#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# verify-release-tag.sh tag <name> | rehearse
#
# Is a release tag signed by the LibreSCRS release key? One judgement, used by
# both modes, so a rehearsal proves the code the tag will run:
#
#   tag <name>   judge that tag in the consumer's checkout (REPO_ROOT). The
#                release workflow on a tag push, and release-train locally
#                before it pushes a tag, both call this.
#   rehearse     judge fixtures on the runner, both ways, with the consumer's
#                own KEYS: the published LibreMiddleware 4.2.0 tag must be
#                ACCEPTED; a tag signed by a throwaway key (unknown to the
#                keyring, then known to it), an unsigned annotated tag, the
#                4.2.0 signature over altered content, and the genuine 4.2.0
#                object presented under another name must all be REJECTED.
#                A branch carries no signed tag, so this is what a rehearsal
#                can prove instead -- and it proves the verifier can say no.
#
# The judgement (unchanged from the release workflows it replaces):
#   * a FRESH keyring holding only the repository's KEYS file, never the
#     caller's own -- locally that keyring holds the secret key and every key
#     ever imported;
#   * `git verify-tag --raw`, and the signer pinned by fingerprint through the
#     VALIDSIG status line. verify-tag alone accepts a good signature by ANY key
#     in the keyring.
#   * Field order is the whole trick. VALIDSIG's FIRST field is the key that
#     physically signed, and this project signs with a SUBKEY (the primary is
#     certify-only), so the first field is the subkey. The primary -- the
#     identity worth pinning, because it outlives every subkey rotation -- is
#     VALIDSIG's LAST field. Anchored, and never a bare fingerprint grep: gpg
#     emits KEY_CONSIDERED with the primary's fingerprint even for a BADSIG.
#   * the tag OBJECT's own name must be the name asked about: a genuinely
#     signed 4.2.0 object pushed under refs/tags/5.0.0 verifies, and would
#     publish old bytes as a new release.
#
# Inputs (environment):
#   REPO_ROOT       the consumer checkout (default $GITHUB_WORKSPACE, then the
#                   git toplevel of the current directory)
#   KEYS_FILE       default $REPO_ROOT/KEYS
#   EXPECTED_FPR    default 6B05889AC9A6A7188DF639B06F27A989C2031D16 (primary)
#   FIXTURE_REMOTE  default https://github.com/LibreSCRS/LibreMiddleware
#   FIXTURE_TAG     default 4.2.0
#
# Exit: 0 accepted (tag) / every fixture judged as expected (rehearse)
#       1 rejected / a fixture judged wrongly
#       2 cannot judge: no KEYS, no gpg or git, the fixture unreachable.
set -uo pipefail

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "FATAL: needs bash >= 4 -- cannot judge" >&2; exit 2; }

EXPECTED_FPR="${EXPECTED_FPR:-6B05889AC9A6A7188DF639B06F27A989C2031D16}"
FIXTURE_REMOTE="${FIXTURE_REMOTE:-https://github.com/LibreSCRS/LibreMiddleware}"
FIXTURE_TAG="${FIXTURE_TAG:-4.2.0}"

usage() { echo "FATAL: usage: verify-release-tag.sh tag <name> | rehearse" >&2; exit 2; }
cannot() { echo "FATAL: $* -- cannot judge" >&2; exit 2; }

[ "$#" -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
    tag) [ "$#" -eq 1 ] && [ -n "$1" ] || usage ;;
    rehearse) [ "$#" -eq 0 ] || usage ;;
    *) usage ;;
esac

[[ "$EXPECTED_FPR" =~ ^[0-9A-F]{40}$ ]] || cannot "EXPECTED_FPR '$EXPECTED_FPR' is not a 40-hex upper-case fingerprint"
command -v git >/dev/null 2>&1 || cannot "git is not on PATH"
command -v gpg >/dev/null 2>&1 || cannot "gpg is not on PATH"

root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
[ -n "$root" ] && [ -d "$root" ] || cannot "no consumer tree (set REPO_ROOT)"
KEYS_FILE="${KEYS_FILE:-$root/KEYS}"
[ -f "$KEYS_FILE" ] || cannot "no KEYS at $KEYS_FILE -- a release tag cannot be verified without the published release public key"

work="$(mktemp -d "${TMPDIR:-/var/tmp}/verify-release-tag.XXXXXX")" || cannot "mktemp failed"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    GNUPGHOME="$work/keyring" gpgconf --kill all >/dev/null 2>&1 || true
    GNUPGHOME="$work/forger" gpgconf --kill all >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# A fresh keyring holding the repository's KEYS and nothing else.
mkdir -m 700 "$work/keyring"
export GNUPGHOME="$work/keyring"
gpg --batch --quiet --import "$KEYS_FILE" >"$work/import.log" 2>&1 \
    || { sed 's/^/  | /' "$work/import.log" >&2; cannot "gpg could not import $KEYS_FILE"; }
# The pinned fingerprint must be a PRIMARY key in that file: `pub`, followed by
# its own `fpr` line -- not a subkey that happens to carry the same digits.
if ! gpg --batch --with-colons --list-keys "$EXPECTED_FPR" 2>/dev/null \
        | awk -F: -v f="$EXPECTED_FPR" '$1=="pub"{p=1; next} p && $1=="fpr"{ if ($10==f) ok=1; p=0 } END{ exit !ok }'; then
    echo "::error::$KEYS_FILE does not carry the release key $EXPECTED_FPR as a primary key -- import failed or fingerprint mismatch"
    exit 1
fi

# judge <git-dir> <ref> <expected-object-name> -> 0 accept, 1 reject.
# The ONE judgement both modes run.
judge() {
    local gd=$1 ref=$2 want=$3 kind name out vrc
    kind="$(git -C "$gd" cat-file -t "refs/tags/$ref" 2>/dev/null)"
    if [ "$kind" != tag ]; then
        echo "  $ref: not an annotated tag object (${kind:-absent})"
        return 1
    fi
    name="$(git -C "$gd" cat-file tag "refs/tags/$ref" | sed -n 's/^tag //p' | head -n 1)"
    if [ "$name" != "$want" ]; then
        echo "  $ref: the tag object calls itself '$name', not '$want' -- a signed object under another name"
        return 1
    fi
    # Two conditions, each enough to refuse on its own: gpg's own verdict, and
    # a VALIDSIG line whose LAST field is the pinned primary.
    out="$(git -C "$gd" verify-tag --raw "refs/tags/$ref" 2>&1)"; vrc=$?
    if [ "$vrc" -eq 0 ] \
            && printf '%s\n' "$out" | grep -qE "^\[GNUPG:\] VALIDSIG [0-9A-F]{40} .* ${EXPECTED_FPR}\$"; then
        echo "  $ref: VALIDSIG by the release key $EXPECTED_FPR"
        return 0
    fi
    echo "  $ref: no VALIDSIG line ending in $EXPECTED_FPR"
    return 1
}

if [ "$cmd" = tag ]; then
    t=$1
    git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || cannot "$root is not a git checkout"
    if judge "$root" "$t" "$t"; then
        echo "verify-release-tag: $t is signed by the LibreSCRS release key"
        exit 0
    fi
    echo "::error::Tag $t is not signed by the LibreSCRS release key"
    exit 1
fi

# ---------------------------------------------------------------- rehearse --
fx="$work/fixture"
git init -q "$fx" || cannot "git init failed"
if ! git -C "$fx" fetch -q --no-tags --depth=1 "$FIXTURE_REMOTE" \
        "refs/tags/$FIXTURE_TAG:refs/tags/_fixture" >"$work/fetch.log" 2>&1; then
    sed 's/^/  | /' "$work/fetch.log" >&2
    cannot "the fixture tag $FIXTURE_TAG could not be fetched from $FIXTURE_REMOTE"
fi
commit="$(git -C "$fx" rev-parse "refs/tags/_fixture^{commit}")" || cannot "the fixture tag points at no commit"
gitc=(git -C "$fx" -c user.name=rehearsal -c user.email=rehearsal@invalid -c tag.gpgSign=false)

# The same signed object under another name.
git -C "$fx" update-ref refs/tags/_replayed "$(git -C "$fx" rev-parse refs/tags/_fixture)"

# The genuine signature over altered content: a BADSIG, for which gpg still
# prints KEY_CONSIDERED with the release key's primary fingerprint.
git -C "$fx" cat-file tag refs/tags/_fixture \
    | awk 'BEGIN{done=0} /^$/ && !done { print; print "altered after signing"; done=1; next } { print }' \
    > "$work/tampered.obj"
tampered="$(git -C "$fx" mktag < "$work/tampered.obj" 2>"$work/mktag.log")" \
    || { sed 's/^/  | /' "$work/mktag.log" >&2; cannot "could not build the altered-content fixture"; }
git -C "$fx" update-ref refs/tags/_tampered "$tampered"

"${gitc[@]}" tag -a -m "unsigned" _unsigned "$commit" || cannot "could not build the unsigned fixture"

# A throwaway key in its own keyring signs _forged.
mkdir -m 700 "$work/forger"
GNUPGHOME="$work/forger" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Rehearsal Forger <forger@invalid>" ed25519 sign 1d >/dev/null 2>&1 \
    || cannot "gpg could not generate the throwaway key"
ffpr="$(GNUPGHOME="$work/forger" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
[ -n "$ffpr" ] || cannot "the throwaway key has no fingerprint"
GNUPGHOME="$work/forger" "${gitc[@]}" -c user.signingKey="$ffpr" -c gpg.format=openpgp \
    tag -s -m "forged" _forged "$commit" >/dev/null 2>&1 || cannot "the throwaway key could not sign _forged"

bad=0
expect() {  # expect <accept|reject> <ref> <object-name> <what>
    local want=$1 ref=$2 name=$3 what=$4 got
    if judge "$fx" "$ref" "$name"; then got=accept; else got=reject; fi
    if [ "$got" = "$want" ]; then
        printf 'ok    %-7s %s\n' "$got" "$what"
    else
        printf '::error::%s was %sED, must be %sED -- the verifier cannot be trusted with the real tag\n' \
            "$what" "${got^^}" "${want^^}"
        bad=1
    fi
}
expect accept _fixture  "$FIXTURE_TAG"  "$FIXTURE_TAG from $FIXTURE_REMOTE (signed by the release key's subkey)"
expect reject _forged   _forged         "a tag signed by a throwaway key the keyring does not know"
expect reject _unsigned _unsigned       "an unsigned annotated tag"
expect reject _tampered "$FIXTURE_TAG"  "the $FIXTURE_TAG signature over altered content (BADSIG)"
expect reject _replayed 5.0.0-replay    "the genuine $FIXTURE_TAG object under another name"
# The keyring now knows the throwaway key too: verify-tag alone says "good
# signature", and only the fingerprint pin stands between it and a release.
GNUPGHOME="$work/forger" gpg --batch --armor --export "$ffpr" 2>/dev/null \
    | gpg --batch --quiet --import >/dev/null 2>&1 || cannot "could not import the throwaway public key"
expect reject _forged   _forged         "the throwaway-key tag once the keyring knows that key"

if [ "$bad" = 0 ]; then
    echo "verify-release-tag: rehearsal proved the verifier both ways (1 accepted, 5 rejected)"
    exit 0
fi
exit 1
