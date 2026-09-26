#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# release-seal.sh -- checksums, signatures and their verification for a
# release's asset directory, in the one shape both release modes share.
#
#   seal <publish|rehearse> <dir>
#       SHA256SUMS over every file in <dir>, then one cosign bundle
#       (<file>.sigstore.json) per file, SHA256SUMS included, then every
#       bundle verified and `sha256sum -c` run -- in the same call, so nothing
#       leaves this step unverified.
#         publish   keyless (Fulcio certificate, Rekor entry), verified against
#                   the EXACT identity identity_for($GITHUB_REPOSITORY,
#                   $GITHUB_REF) and the Actions OIDC issuer.
#         rehearse  an ephemeral key pair made here and thrown away, and a
#                   signing config with no transparency log, no timestamp
#                   authority and no Fulcio: nothing is uploaded anywhere.
#                   Verified with that key. A branch cannot obtain the
#                   certificate a tag will, so the keyless half is proved by
#                   the two fixture commands below instead.
#   fixture-keyless
#       The keyless VERIFY path, run against releases that exist: for each
#       fixture (default: LibreMiddleware and LibreCelik 4.2.0), download one
#       asset and its bundle, then
#         ACCEPT  identity_for(<repo>, refs/tags/<tag>)       -- the function
#                 the tag run uses, with the fixture's ref
#         ACCEPT  the identity regex the website publishes for users
#         REJECT  the same identity for another repository, another tag, a
#                 branch; and the genuine identity over altered bytes
#       and hold the identity a tag of THIS version will carry to the
#       website's regex (it must match), and the identity this rehearsal runs
#       under to it (a branch must NOT match).
#   fixture-attest
#       The same for `gh attestation verify`, over a public attested artefact
#       (default: cli/cli v2.100.0, built by deployment.yml on refs/heads/trunk)
#       through attest_verify, the function the tag run uses.
#   attest-verify <dir>
#       After actions/attest-build-provenance on a tag: every file named in
#       <dir>/SHA256SUMS verified through attest_verify with this run's
#       repository, release.yml and ref.
#   identity <repo> <ref>
#       Print identity_for, for release-train and for a reader.
#
# Tools: cosign (v3; the composite action installs it pinned), gh (for the
# fixtures and attest-verify; GH_TOKEN), sha256sum or shasum.
#
# Exit: 0 sealed / every fixture judged as expected - 1 a verification failed
#       or a fixture was judged wrongly, or <dir> is not sealable (empty, a
#       subdirectory, bundles already present) - 2 cannot judge (a tool
#       missing, a fixture unreachable, a usage error).
set -uo pipefail

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "FATAL: needs bash >= 4 -- cannot judge" >&2; exit 2; }

ISSUER=https://token.actions.githubusercontent.com
KEYLESS_FIXTURES="${KEYLESS_FIXTURES:-LibreSCRS/LibreMiddleware 4.2.0 librescrs-pkcs11-4.2.0-linux-x86_64.tar.gz
LibreSCRS/LibreCelik 4.2.0 LibreCelik-4.2.0-macos.dmg}"
ATTEST_FIXTURE="${ATTEST_FIXTURE:-cli/cli v2.100.0 gh_2.100.0_linux_arm64.tar.gz deployment.yml refs/heads/trunk}"
SITE_REPO="${SITE_REPO:-LibreSCRS/LibreSCRS.github.io}"
SITE_POLICY_PATH="${SITE_POLICY_PATH:-content/security/_index.md}"

cannot() { echo "FATAL: $* -- cannot judge" >&2; exit 2; }
usage() {
    echo "FATAL: usage: release-seal.sh seal <publish|rehearse> <dir> | fixture-keyless | fixture-attest | attest-verify <dir> | identity <repo> <ref>" >&2
    exit 2
}
need() { command -v "$1" >/dev/null 2>&1 || cannot "$1 is not on PATH"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# The ONE place a signer identity is spelled. The tag run verifies against it,
# the fixture proof accepts and rejects through it, release-train verifies the
# downloaded assets through it.
identity_for() {  # identity_for <owner/repo> <full ref>
    printf 'https://github.com/%s/.github/workflows/release.yml@%s' "$1" "$2"
}

# The ONE shape of an attestation check (the tag run, the fixture, release-train).
attest_verify() {  # attest_verify <file> <owner/repo> <workflow file> <full ref>
    gh attestation verify "$1" --repo "$2" \
        --signer-workflow "$2/.github/workflows/$3" --source-ref "$4" >/dev/null 2>&1
}

keyless_verify() {  # keyless_verify <file> <identity> -> cosign's verdict
    cosign verify-blob "$1" --bundle "$1.sigstore.json" \
        --certificate-identity "$2" --certificate-oidc-issuer "$ISSUER" >/dev/null 2>&1
}

work="$(mktemp -d "${TMPDIR:-/var/tmp}/release-seal.XXXXXX")" || cannot "mktemp failed"
trap 'rm -rf "$work"' EXIT

bad=0
judged() {  # judged <want accept|reject> <got 0|nonzero> <what>
    local got=reject
    [ "$2" = 0 ] && got=accept
    if [ "$got" = "$1" ]; then
        printf 'ok    %-7s %s\n' "$got" "$3"
    else
        printf '::error::%s was %sED, must be %sED\n' "$3" "${got^^}" "${1^^}"
        bad=1
    fi
}

# ------------------------------------------------------------------- seal --
seal() {
    local mode=$1 dir=$2 f n=0 identity=""
    case "$mode" in publish|rehearse) ;; *) usage ;; esac
    [ -d "$dir" ] || cannot "no asset directory $dir"
    need cosign
    while IFS= read -r -d '' f; do
        if [ -d "$f" ]; then
            echo "::error::$dir holds a directory ($(basename -- "$f")) -- a release asset is a file"
            return 1
        fi
        case "$f" in
            *.sigstore.json|*/SHA256SUMS)
                echo "::error::$dir already holds $(basename -- "$f") -- a seal made elsewhere would be published unverified"
                return 1 ;;
        esac
        n=$((n + 1))
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
    if [ "$n" -eq 0 ]; then
        echo "::error::$dir holds no asset -- a signed SHA256SUMS over nothing is not a release"
        return 1
    fi

    ( cd "$dir" && find . -mindepth 1 -maxdepth 1 -type f -print | sed 's|^\./||' | LC_ALL=C sort \
        | while IFS= read -r f; do sha256 "$f"; done ) > "$work/SHA256SUMS" \
        || { echo "::error::could not checksum $dir"; return 1; }
    mv "$work/SHA256SUMS" "$dir/SHA256SUMS"
    echo "SHA256SUMS over $n asset(s):"
    sed 's/^/  /' "$dir/SHA256SUMS"

    local sign=(cosign sign-blob --yes) verify=()
    if [ "$mode" = publish ]; then
        [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_REF:-}" ] \
            || cannot "GITHUB_REPOSITORY and GITHUB_REF are needed to name the signer"
        identity="$(identity_for "$GITHUB_REPOSITORY" "$GITHUB_REF")"
        echo "keyless: signing as $identity"
    else
        # Nothing here reaches a public service: no Fulcio (a key signs), no
        # Rekor and no TSA (the signing config names none).
        COSIGN_PASSWORD='' cosign generate-key-pair --output-key-prefix "$work/rehearsal" >/dev/null 2>&1 \
            || cannot "cosign could not generate the ephemeral key pair"
        cosign signing-config create --no-default-fulcio --no-default-rekor --no-default-oidc \
            --no-default-tsa --out "$work/signing-config.json" >/dev/null 2>&1 \
            || cannot "cosign could not write a signing config without a transparency log"
        sign+=(--key "$work/rehearsal.key" --signing-config "$work/signing-config.json")
        verify=(--key "$work/rehearsal.pub" --insecure-ignore-tlog=true)
        echo "rehearsal: signing with an ephemeral key, no transparency log"
    fi

    while IFS= read -r -d '' f; do
        COSIGN_PASSWORD='' "${sign[@]}" --bundle "$f.sigstore.json" "$f" >"$work/sign.log" 2>&1 \
            || { sed 's/^/  | /' "$work/sign.log"; echo "::error::cosign could not sign $(basename -- "$f")"; return 1; }
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f ! -name '*.sigstore.json' -print0)

    local rc=0
    while IFS= read -r -d '' f; do
        if [ "$mode" = publish ]; then
            keyless_verify "$f" "$identity"
        else
            cosign verify-blob "$f" --bundle "$f.sigstore.json" "${verify[@]}" >/dev/null 2>&1
        fi || { echo "::error::the bundle for $(basename -- "$f") does not verify"; rc=1; continue; }
        echo "verified  $(basename -- "$f")"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f ! -name '*.sigstore.json' -print0)
    ( cd "$dir" && sha256 -c SHA256SUMS >/dev/null ) \
        || { echo "::error::sha256sum -c SHA256SUMS fails in $dir"; rc=1; }
    [ "$rc" = 0 ] && echo "release-seal: $n asset(s) + SHA256SUMS sealed and verified ($mode)"
    return "$rc"
}

# ------------------------------------------------------- the site's policy --
site_regex() {
    local page="${SITE_POLICY_FILE:-}"
    if [ -z "$page" ]; then
        need gh
        page="$work/site-policy.md"
        gh api "repos/$SITE_REPO/contents/$SITE_POLICY_PATH" --jq .content 2>/dev/null \
            | { base64 -d 2>/dev/null || base64 -D; } > "$page" \
            || cannot "could not read $SITE_POLICY_PATH from $SITE_REPO"
    fi
    sed -n "s/.*--certificate-identity-regexp '\([^']*\)'.*/\1/p" "$page" | head -n 1
}

# ------------------------------------------------------- fixture-keyless --
fixture_keyless() {
    need cosign; need gh
    local regex repo tag asset f n=0
    regex="$(site_regex)"
    [ -n "$regex" ] || cannot "the site's security page publishes no --certificate-identity-regexp"
    echo "site policy regex: $regex"

    while read -r repo tag asset; do
        [ -n "$repo" ] || continue
        n=$((n + 1))
        mkdir -p "$work/k$n"
        gh release download "$tag" -R "$repo" -D "$work/k$n" -p "$asset" -p "$asset.sigstore.json" \
            >/dev/null 2>&1 || cannot "could not download $asset(.sigstore.json) from $repo $tag"
        f="$work/k$n/$asset"
        [ -f "$f" ] && [ -f "$f.sigstore.json" ] || cannot "$repo $tag did not yield $asset and its bundle"
        local other="LibreSCRS/LibreAgent"
        [ "$repo" = "$other" ] && other="LibreSCRS/LibreMiddleware"
        keyless_verify "$f" "$(identity_for "$repo" "refs/tags/$tag")"; \
            judged accept $? "$repo $tag: identity_for($repo, refs/tags/$tag)"
        cosign verify-blob "$f" --bundle "$f.sigstore.json" --certificate-identity-regexp "$regex" \
            --certificate-oidc-issuer "$ISSUER" >/dev/null 2>&1; \
            judged accept $? "$repo $tag: the website's identity regex"
        keyless_verify "$f" "$(identity_for "$other" "refs/tags/$tag")"; \
            judged reject $? "$repo $tag: identity_for($other, refs/tags/$tag) -- another repository"
        keyless_verify "$f" "$(identity_for "$repo" "refs/tags/$tag.1")"; \
            judged reject $? "$repo $tag: identity_for($repo, refs/tags/$tag.1) -- another tag"
        keyless_verify "$f" "$(identity_for "$repo" "refs/heads/main")"; \
            judged reject $? "$repo $tag: identity_for($repo, refs/heads/main) -- a branch"
        cp "$f" "$f.altered" && printf 'x' >> "$f.altered" && cp "$f.sigstore.json" "$f.altered.sigstore.json"
        keyless_verify "$f.altered" "$(identity_for "$repo" "refs/tags/$tag")"; \
            judged reject $? "$repo $tag: the genuine identity over altered bytes"
    done <<< "$KEYLESS_FIXTURES"
    [ "$n" -gt 0 ] || cannot "no keyless fixture named"

    # The identity THIS repository's tag will carry must pass the published
    # policy, and the one this run carries must not (a rehearsal's signature
    # can never stand in for a release's).
    if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${RELEASE_VERSION:-}" ]; then
        printf '%s' "$(identity_for "$GITHUB_REPOSITORY" "refs/tags/$RELEASE_VERSION")" | grep -qE -- "$regex"; \
            judged accept $? "the website's regex over identity_for($GITHUB_REPOSITORY, refs/tags/$RELEASE_VERSION)"
        case "${GITHUB_REF:-}" in
            refs/tags/*) ;;
            ?*) printf '%s' "$(identity_for "$GITHUB_REPOSITORY" "$GITHUB_REF")" | grep -qE -- "$regex"; \
                judged reject $? "the website's regex over this rehearsal's identity ($GITHUB_REF)" ;;
        esac
    else
        echo "note: GITHUB_REPOSITORY/RELEASE_VERSION unset -- the policy check of this repository's own identity is skipped"
    fi
    [ "$bad" = 0 ] && echo "release-seal: keyless verification proved both ways over $n published release(s)"
    return "$bad"
}

# -------------------------------------------------------- fixture-attest --
fixture_attest() {
    need gh
    local repo tag asset wf ref f
    read -r repo tag asset wf ref <<< "$ATTEST_FIXTURE"
    [ -n "$ref" ] || cannot "ATTEST_FIXTURE must be '<repo> <tag> <asset> <workflow file> <ref>'"
    gh release download "$tag" -R "$repo" -D "$work/a" -p "$asset" >/dev/null 2>&1 \
        || cannot "could not download $asset from $repo $tag"
    f="$work/a/$asset"
    [ -f "$f" ] || cannot "$repo $tag did not yield $asset"
    attest_verify "$f" "$repo" "$wf" "$ref"; judged accept $? "$repo $asset: attest_verify($repo, $wf, $ref)"
    attest_verify "$f" "$repo" "$wf" "refs/tags/$tag"; judged reject $? "$repo $asset: another source ref"
    attest_verify "$f" "$repo" "release.yml" "$ref"; judged reject $? "$repo $asset: another signer workflow"
    attest_verify "$f" "LibreSCRS/LibreMiddleware" "$wf" "$ref"; judged reject $? "$repo $asset: another repository"
    [ "$bad" = 0 ] && echo "release-seal: attestation verification proved both ways over $repo $tag"
    return "$bad"
}

# --------------------------------------------------------- attest-verify --
attest_verify_dir() {
    local dir=$1 name rc=0 n=0
    need gh
    [ -f "$dir/SHA256SUMS" ] || cannot "no $dir/SHA256SUMS to take the subjects from"
    [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_REF:-}" ] || cannot "GITHUB_REPOSITORY and GITHUB_REF are needed"
    while read -r _ name; do
        name="${name#\*}"
        n=$((n + 1))
        if attest_verify "$dir/$name" "$GITHUB_REPOSITORY" release.yml "$GITHUB_REF"; then
            echo "attested  $name"
        else
            echo "::error::$name has no provenance attestation from $GITHUB_REPOSITORY release.yml at $GITHUB_REF"
            rc=1
        fi
    done < "$dir/SHA256SUMS"
    [ "$n" -gt 0 ] || { echo "::error::$dir/SHA256SUMS names nothing"; return 1; }
    return "$rc"
}

[ "$#" -ge 1 ] || usage
case "$1" in
    seal)            [ "$#" -eq 3 ] || usage; seal "$2" "$3" ;;
    fixture-keyless) [ "$#" -eq 1 ] || usage; fixture_keyless ;;
    fixture-attest)  [ "$#" -eq 1 ] || usage; fixture_attest ;;
    attest-verify)   [ "$#" -eq 2 ] || usage; attest_verify_dir "$2" ;;
    identity)        [ "$#" -eq 3 ] || usage; identity_for "$2" "$3"; echo ;;
    *) usage ;;
esac
