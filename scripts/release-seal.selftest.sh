#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC1003,SC1007,SC2010,SC2012,SC2015,SC2016,SC2028,SC2181  # fixture text is literal on purpose; A && B || C report lines
# Self-test for release-seal.sh, offline: cosign and gh are PATH shims.
#
# The cosign shim is a small model of the one property that matters here: a
# bundle records the digest of what was signed and WHO signed -- an ephemeral
# key's content, or the identity "Fulcio" certified (STUB_SIGNER, set by each
# case as a literal, never computed the way the script computes it; a shim
# that derived the identity with the script's own rule would agree with any
# bug in it). verify-blob accepts only the same digest and the same signer.
# The gh shim serves releases, a site page and attestation records from
# fixture directories.
#
# What the shims cannot prove -- that real cosign and gh behave like this -- is
# proved on the runner by the rehearsal itself (fixture-keyless and
# fixture-attest against published releases), and was measured locally with
# cosign v3.0.6 and gh 2.100.0 before this was written.
set -u

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="$here/release-seal.sh"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }
work="$(mktemp -d "/var/tmp/release-seal-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

cases=0; red=0; fails=0
check() {  # check <name> <want-rc> <needle|-> -- <command...>
    local name=$1 want=$2 needle=$3 out got
    shift 4
    cases=$((cases + 1))
    [ "$want" != 0 ] && red=$((red + 1))
    out="$("$@" 2>&1)"; got=$?
    if [ "$got" != "$want" ]; then
        printf 'FAIL  %s: rc=%s, want %s\n' "$name" "$got" "$want"
        printf '%s\n' "$out" | sed 's/^/  | /'
        fails=$((fails + 1)); return
    fi
    if [ "$needle" != - ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
        printf 'FAIL  %s: rc=%s as wanted, but the output does not say "%s"\n' "$name" "$got" "$needle"
        printf '%s\n' "$out" | sed 's/^/  | /'
        fails=$((fails + 1)); return
    fi
    printf 'ok    %s (rc=%s)\n' "$name" "$got"
}

# ----------------------------------------------------------------- shims --
shim="$work/shim"; mkdir -p "$shim"
cat > "$shim/cosign" <<'SH'
#!/usr/bin/env bash
# Model: bundle = "sha=<digest>\nsigner=<who>\nissuer=<issuer>".
dig() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
cmd=$1; shift
case "$cmd" in
  generate-key-pair)
    while [ "$#" -gt 0 ]; do [ "$1" = --output-key-prefix ] && p=$2; shift; done
    k="key-$RANDOM$RANDOM"; printf '%s' "$k" > "$p.key"; printf '%s' "$k" > "$p.pub"; exit 0 ;;
  signing-config)
    while [ "$#" -gt 0 ]; do [ "$1" = --out ] && o=$2; shift; done
    printf '{}' > "$o"; exit 0 ;;
  sign-blob)
    key=""; bundle=""; file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --key) key=$2; shift ;; --bundle) bundle=$2; shift ;;
        --signing-config) shift ;; --yes) ;; *) file=$1 ;;
      esac; shift
    done
    if [ -n "$key" ]; then who="key:$(cat "$key")"; iss=none
    else [ -n "${STUB_SIGNER:-}" ] || { echo "no OIDC token" >&2; exit 1; }; who=$STUB_SIGNER; iss=https://token.actions.githubusercontent.com
    fi
    d=$(dig "$file"); [ -n "${STUB_CORRUPT:-}" ] && d=0000
    printf 'sha=%s\nsigner=%s\nissuer=%s\n' "$d" "$who" "$iss" > "$bundle"; exit 0 ;;
  verify-blob)
    key=""; bundle=""; file=""; id=""; re=""; iss=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --key) key=$2; shift ;; --bundle) bundle=$2; shift ;;
        --certificate-identity) id=$2; shift ;; --certificate-identity-regexp) re=$2; shift ;;
        --certificate-oidc-issuer) iss=$2; shift ;; --insecure-ignore-tlog=true) ;; *) file=$1 ;;
      esac; shift
    done
    [ -f "$bundle" ] || exit 1
    [ "$(sed -n 's/^sha=//p' "$bundle")" = "$(dig "$file")" ] || exit 1
    who=$(sed -n 's/^signer=//p' "$bundle")
    if [ -n "$key" ]; then [ "$who" = "key:$(cat "$key")" ]; exit $?; fi
    [ "$(sed -n 's/^issuer=//p' "$bundle")" = "$iss" ] || exit 1
    if [ -n "$id" ]; then [ "$who" = "$id" ]; exit $?; fi
    if [ -n "$re" ]; then printf '%s' "$who" | grep -qE -- "$re"; exit $?; fi
    exit 0 ;;
esac
echo "cosign shim: $cmd not modelled" >&2; exit 3
SH
cat > "$shim/gh" <<'SH'
#!/usr/bin/env bash
dig() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
case "$1 $2" in
  "release download")
    tag=$3; shift 3; pats=()
    while [ "$#" -gt 0 ]; do
      case "$1" in -R) repo=$2; shift ;; -D) dest=$2; shift ;; -p) pats+=("$2"); shift ;; esac; shift
    done
    src="$STUB_RELEASES/$repo/$tag"; [ -d "$src" ] || exit 1
    mkdir -p "$dest"
    for p in "${pats[@]}"; do [ -f "$src/$p" ] || exit 1; cp "$src/$p" "$dest/"; done; exit 0 ;;
  "api repos/"*)
    [ -f "${STUB_SITE_PAGE:-/nonexistent}" ] || exit 1
    base64 < "$STUB_SITE_PAGE" | tr -d '\n'; echo; exit 0 ;;
  "attestation verify")
    f=$3; shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in --repo) r=$2; shift ;; --signer-workflow) w=$2; shift ;; --source-ref) s=$2; shift ;; esac; shift
    done
    # Like gh: a policy flag that is not given is not checked.
    while read -r hd hr hw hs; do
      [ "$hd" = "$(dig "$f")" ] && [ "$hr" = "$r" ] \
        && { [ -z "${w:-}" ] || [ "$hw" = "$w" ]; } && { [ -z "${s:-}" ] || [ "$hs" = "$s" ]; } && exit 0
    done < "${STUB_ATTESTED:-/dev/null}"
    exit 1 ;;
esac
echo "gh shim: $* not modelled" >&2; exit 3
SH
chmod 755 "$shim/cosign" "$shim/gh"
export PATH="$shim:$PATH"
dig() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }

# Literal identities, spelled out here rather than derived.
ID_LM_420='https://github.com/LibreSCRS/LibreMiddleware/.github/workflows/release.yml@refs/tags/4.2.0'
ID_LC_420='https://github.com/LibreSCRS/LibreCelik/.github/workflows/release.yml@refs/tags/4.2.0'
ID_X_500='https://github.com/LibreSCRS/Example/.github/workflows/release.yml@refs/tags/5.0.0'

# Published fixtures: one asset per release, sealed by "Fulcio" as its release run.
rel="$work/releases"
publish_fixture() {  # publish_fixture <repo> <tag> <asset> <signer>
    local d="$rel/$1/$2"; mkdir -p "$d"
    printf 'bytes of %s\n' "$3" > "$d/$3"
    STUB_SIGNER="$4" cosign sign-blob --yes --bundle "$d/$3.sigstore.json" "$d/$3"
}
publish_fixture LibreSCRS/LibreMiddleware 4.2.0 lm.tar.gz "$ID_LM_420"
publish_fixture LibreSCRS/LibreCelik 4.2.0 lc.dmg "$ID_LC_420"
publish_fixture LibreSCRS/Branchy 4.2.0 b.tar.gz \
    'https://github.com/LibreSCRS/Branchy/.github/workflows/release.yml@refs/heads/main'
site="$work/site.md"
cat > "$site" <<'MD'
cosign verify-blob <artifact> \
  --bundle <artifact>.sigstore.json \
  --certificate-identity-regexp 'https://github\.com/LibreSCRS/.*\.github/workflows/release\.yml@refs/tags/.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
MD
export STUB_RELEASES="$rel" STUB_SITE_PAGE="$site"
fx2='LibreSCRS/LibreMiddleware 4.2.0 lm.tar.gz
LibreSCRS/LibreCelik 4.2.0 lc.dmg'

assets() {  # assets <dir>: a fresh asset directory with two files
    rm -rf "$1"; mkdir -p "$1"; printf 'a\n' > "$1/a.tar.gz"; printf 'b\n' > "$1/b.deb"
}
seal() { env -u GITHUB_REPOSITORY -u GITHUB_REF "$@"; }

# ------------------------------------------------------------------- seal --
d="$work/s1"; assets "$d"
check "S1 rehearse seals two assets and SHA256SUMS" 0 "2 asset(s) + SHA256SUMS sealed and verified (rehearse)" -- \
    seal bash "$subject" seal rehearse "$d"
cases=$((cases + 1))
if [ -f "$d/SHA256SUMS.sigstore.json" ] && [ "$(wc -l < "$d/SHA256SUMS")" -eq 2 ] \
        && ! grep -q sigstore "$d/SHA256SUMS" && ! ls "$d" | grep -q '\.key$\|\.pub$'; then
    echo "ok    S1b every file has a bundle, SHA256SUMS names the two assets, no key is left behind"
else
    echo "FAIL  S1b the sealed directory is not the expected shape"; ls -la "$d" | sed 's/^/  | /'; fails=$((fails + 1))
fi
d="$work/s2"; rm -rf "$d"; mkdir -p "$d"
check "S2 an empty directory is not a release" 1 "holds no asset" -- seal bash "$subject" seal rehearse "$d"
d="$work/s3"; assets "$d"; mkdir "$d/sub"
check "S3 a subdirectory in the asset directory" 1 "holds a directory" -- seal bash "$subject" seal rehearse "$d"
d="$work/s4"; assets "$d"; printf 'x' > "$d/a.tar.gz.sigstore.json"
check "S4 a bundle made elsewhere is refused" 1 "already holds a.tar.gz.sigstore.json" -- seal bash "$subject" seal rehearse "$d"
d="$work/s5"; assets "$d"
check "S5 publish verifies against the exact tag identity" 0 "sealed and verified (publish)" -- \
    env STUB_SIGNER="$ID_X_500" GITHUB_REPOSITORY=LibreSCRS/Example GITHUB_REF=refs/tags/5.0.0 \
    bash "$subject" seal publish "$d"
d="$work/s6"; assets "$d"
check "S6 a certificate for another workflow does not verify" 1 "does not verify" -- \
    env STUB_SIGNER='https://github.com/LibreSCRS/Example/.github/workflows/ci.yml@refs/tags/5.0.0' \
    GITHUB_REPOSITORY=LibreSCRS/Example GITHUB_REF=refs/tags/5.0.0 bash "$subject" seal publish "$d"
d="$work/s7"; assets "$d"
check "S7 publish without the run's repository and ref" 2 "needed to name the signer" -- \
    seal env STUB_SIGNER="$ID_X_500" bash "$subject" seal publish "$d"
d="$work/s8"; assets "$d"
check "S8 a bundle that does not match the bytes" 1 "does not verify" -- \
    seal env STUB_CORRUPT=1 bash "$subject" seal rehearse "$d"
d="$work/s9"; assets "$d"; mkdir -p "$work/nocosign"
for t in bash sed find sort mktemp rm mv cat cut grep sha256sum shasum; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$work/nocosign/$t"
done
check "S9 no cosign on PATH" 2 "cosign is not on PATH" -- \
    env PATH="$work/nocosign" "$work/nocosign/bash" "$subject" seal rehearse "$d"
check "S10 an unknown mode" 2 "usage" -- seal bash "$subject" seal draft "$work/s1"
check "I1 the identity for a tag, spelled out" 0 "$ID_X_500" -- bash "$subject" identity LibreSCRS/Example refs/tags/5.0.0

# -------------------------------------------------------- fixture-keyless --
fk() { env KEYLESS_FIXTURES="$fx2" GITHUB_REPOSITORY=LibreSCRS/Example RELEASE_VERSION=5.0.0 \
       GITHUB_REF=refs/heads/ci/5.0 "$@"; }
check "K1 the published fixtures, both ways" 0 "proved both ways over 2 published release(s)" -- \
    fk bash "$subject" fixture-keyless
check "K2 a fixture signed from a branch is not accepted as its tag" 1 "must be ACCEPTED" -- \
    env KEYLESS_FIXTURES='LibreSCRS/Branchy 4.2.0 b.tar.gz' bash "$subject" fixture-keyless
printf 'no policy on this page\n' > "$work/nopolicy.md"
check "K3 a site page with no identity regex" 2 "publishes no --certificate-identity-regexp" -- \
    fk env STUB_SITE_PAGE="$work/nopolicy.md" bash "$subject" fixture-keyless
sed 's|@refs/tags/\.\*|@refs/heads/.*|' "$site" > "$work/branchpolicy.md"
check "K4 a site regex that no tag identity satisfies" 1 "the website's identity regex was REJECTED" -- \
    fk env STUB_SITE_PAGE="$work/branchpolicy.md" bash "$subject" fixture-keyless
sed 's|@refs/tags/\.\*|@.*|' "$site" > "$work/anypolicy.md"
check "K5 a site regex a rehearsal identity would satisfy" 1 "this rehearsal's identity (refs/heads/ci/5.0) was ACCEPTED" -- \
    fk env STUB_SITE_PAGE="$work/anypolicy.md" bash "$subject" fixture-keyless
check "K6 a fixture that cannot be downloaded" 2 "could not download" -- \
    env KEYLESS_FIXTURES='LibreSCRS/Nowhere 4.2.0 x.tar.gz' bash "$subject" fixture-keyless

perturb() {  # perturb <id> <old> <new>: a copy of the subject with one literal clause replaced
    python3 - "$subject" "$work/$1.sh" "$2" "$3" <<'PY' || { echo "FAIL  $1: the clause is not in the subject"; fails=$((fails + 1)); }
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if old not in t:
    sys.exit(1)
open(dst, "w").write(t.replace(old, new))
PY
    PERTURBED="$work/$1.sh"
}
# P1 -- the identity without its ref: the fixture proof must catch it, since a
# verify-blob against it accepts nothing (and would accept any ref if cosign
# matched prefixes).
perturb P1 "printf 'https://github.com/%s/.github/workflows/release.yml@%s' \"\$1\" \"\$2\"" \
           "printf 'https://github.com/%s/.github/workflows/release.yml' \"\$1\""
check "P1 an identity without the ref is caught by the fixtures" 1 "must be ACCEPTED" -- fk bash "$PERTURBED" fixture-keyless
# P2 -- verification that names no identity: every reject case goes through.
perturb P2 '--certificate-identity "$2" --certificate-oidc-issuer "$ISSUER"' '--certificate-oidc-issuer "$ISSUER"'
check "P2 a verify without the identity is caught by the fixtures" 1 "another repository was ACCEPTED" -- fk bash "$PERTURBED" fixture-keyless

# --------------------------------------------------------- fixture-attest --
art="$rel/cli/cli/v2.100.0"; mkdir -p "$art"; printf 'gh\n' > "$art/gh.tar.gz"
att="$work/attested"
printf '%s cli/cli cli/cli/.github/workflows/deployment.yml refs/heads/trunk\n' "$(dig "$art/gh.tar.gz")" > "$att"
fa() { env ATTEST_FIXTURE='cli/cli v2.100.0 gh.tar.gz deployment.yml refs/heads/trunk' STUB_ATTESTED="$att" "$@"; }
check "A1 the attested fixture, both ways" 0 "attestation verification proved both ways" -- fa bash "$subject" fixture-attest
printf '%s cli/cli cli/cli/.github/workflows/deployment.yml refs/tags/v2.100.0\n' "$(dig "$art/gh.tar.gz")" > "$work/attested-tag"
check "A2 an attestation for another ref is not accepted" 1 "must be ACCEPTED" -- \
    fa env STUB_ATTESTED="$work/attested-tag" bash "$subject" fixture-attest
perturb P3 ' --source-ref "$4" ' ' '
check "P3 an attestation check without --source-ref is caught" 1 "another source ref was ACCEPTED" -- fa bash "$PERTURBED" fixture-attest
check "A3 a malformed fixture description" 2 "ATTEST_FIXTURE must be" -- \
    env ATTEST_FIXTURE='cli/cli v2.100.0' bash "$subject" fixture-attest

# ---------------------------------------------------------- attest-verify --
d="$work/v1"; assets "$d"; seal bash "$subject" seal rehearse "$d" >/dev/null 2>&1
: > "$work/attested-run"
while read -r s _; do
    printf '%s LibreSCRS/Example LibreSCRS/Example/.github/workflows/release.yml refs/tags/5.0.0\n' "$s" >> "$work/attested-run"
done < "$d/SHA256SUMS"
av() { env STUB_ATTESTED="$work/attested-run" GITHUB_REPOSITORY=LibreSCRS/Example GITHUB_REF=refs/tags/5.0.0 "$@"; }
check "V1 every asset in SHA256SUMS is attested" 0 "attested  b.deb" -- av bash "$subject" attest-verify "$d"
head -n 1 "$work/attested-run" > "$work/attested-one"
check "V2 one asset without provenance" 1 "has no provenance attestation" -- \
    av env STUB_ATTESTED="$work/attested-one" bash "$subject" attest-verify "$d"
check "V3 no SHA256SUMS to take subjects from" 2 "no $work/s2/SHA256SUMS" -- av bash "$subject" attest-verify "$work/s2"

# --------------------------------------------------------- verify-release --
# A downloaded release as the train sees it after a tag: sealed by "Fulcio"
# as that tag's run, attested for that tag.
d="$work/r1"; assets "$d"
env STUB_SIGNER="$ID_X_500" GITHUB_REPOSITORY=LibreSCRS/Example GITHUB_REF=refs/tags/5.0.0 \
    bash "$subject" seal publish "$d" >/dev/null 2>&1
vr() { env STUB_ATTESTED="$work/attested-r1" "$@"; }
: > "$work/attested-r1"
while read -r s _; do
    printf '%s LibreSCRS/Example LibreSCRS/Example/.github/workflows/release.yml refs/tags/5.0.0\n' "$s" >> "$work/attested-r1"
done < "$d/SHA256SUMS"
check "D1 a release sealed and attested for its tag" 0 "3 file(s) verified" -- \
    vr bash "$subject" verify-release "$d" LibreSCRS/Example refs/tags/5.0.0
check "D2 the same release judged as another tag's" 1 "does not verify as" -- \
    vr bash "$subject" verify-release "$d" LibreSCRS/Example refs/tags/5.0.1
command cp -f "$d/a.tar.gz" "$work/a.keep"; printf 'x' >> "$d/a.tar.gz"
check "D3 a downloaded asset that is not the checksummed one" 1 "sha256sum -c SHA256SUMS fails" -- \
    vr bash "$subject" verify-release "$d" LibreSCRS/Example refs/tags/5.0.0
command cp -f "$work/a.keep" "$d/a.tar.gz"
check "D4 an asset without provenance" 1 "has no provenance attestation" -- \
    vr env STUB_ATTESTED=/dev/null bash "$subject" verify-release "$d" LibreSCRS/Example refs/tags/5.0.0
mkdir -p "$work/r-empty"
check "D5 a notes-only release has nothing to verify" 0 "publishes no asset" -- \
    bash "$subject" verify-release "$work/r-empty" LibreSCRS/Example refs/tags/5.0.0
d="$work/r6"; assets "$d"
check "D6 assets without SHA256SUMS" 1 "no SHA256SUMS" -- \
    bash "$subject" verify-release "$d" LibreSCRS/Example refs/tags/5.0.0

if [ "$fails" -eq 0 ]; then
    echo "release-seal selftest: all cases passed"
else
    echo "release-seal selftest: $fails case(s) failed"
fi
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
[ "$fails" -eq 0 ]
