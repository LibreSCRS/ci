#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-repo-probe-inside.sh -- one client of the publisher's probe, run by
# pkg-repo-probe.sh in a clean container of one distribution, on the probe
# network where librescrs.github.io is the probe's server.
#
# Environment:
#   SLUG      debian13 | ubuntu2604 | fedora43 | fedora44 | opensusetw
#   MANAGER   apt | dnf | zypper (pkg-images manager <slug>)
#   STEP      p1p2 | forge-a | forge-b | forge-c | forge-d | upgrade | key
#   INSTALL   the name of the first-contact file, for messages
#   PROBE_APT_VERIFIER         ubuntu2604: gpgv (default) | sqv (installs sqv and
#                              gpgv-sq: apt 3.2 on Ubuntu has no sqv method and
#                              runs gpgv-sq when it is installed)
#   PROBE_INDEX_FPR            the index subkey the tree's InRelease is signed by
#   PROBE_KEEP_IMAGE_DEFAULTS  1: keep the Tumbleweed image's no-recommends.conf
#   PROBE_NO_ZYPPER_WRAPPER    1: no non-interactive zypper wrapper
#   PROBE_FORGE_KEY            forge steps: the fingerprint of key B (forge-b)
#   PROBE_FORGE_CLAIM          self-test only: judge a forge step by the words
#                              of another forgery (forge-a..forge-d)
#   PROBE_TREE_VERSIONS        upgrade, key: "<package>=<version> ..." -- every
#                              version the tree's index names for this slug
#   PROBE_TREE_GONE            upgrade, key: 1 when the tree has no rpm/<slug>/
#   PROBE_TREE_INDEX           upgrade, key: sha256 of the tree's InRelease (apt)
#                              or repomd.xml (rpm) for this slug
#   PROBE_PASS_TIMEOUT         upgrade, key: the host's deadline for the pass;
#                              the wait for the tree ends PROBE_SYNC_MARGIN
#                              (default 300) seconds before it
# Mounted: /probe/ca.pem (the probe's CA), /probe/install.txt (the
# first-contact file, byte for byte as published); upgrade and key:
# /probe/sync, where the client says "ready" once it has installed from the
# previous generation and the probe says "go" (or "abort") once it serves the
# tree.
#
# The machine is first made what a desktop is: the CA trusted, the tools a
# desktop has, the distribution's own default for Recommends (the Tumbleweed
# CONTAINER image alone turns them off). Every question a package manager would
# ask is answered by its configuration -- never by touching the published text,
# which runs as `bash -euxo pipefail /tmp/i.sh </dev/null`.
#
# P1 runs the first-contact file; P2 judges what it installed: librecelik,
# what librecelik must bring with it, and (but on opensusetw, which LibreKDE
# is not built for) that librekde brings its five parts.
#
# A forge step runs P1 over a forged tree (pkg-repo-probe.sh): it must fail,
# librecelik must not be installed, and P1's output must hold the client's own
# words for that forgery (forge_reason) -- a forgery that installs is
# "forgery installed", a refusal in other words "refused for the wrong reason".
#
# upgrade (P3) and key (P5) run P1 against the previous generation, wait for
# the tree, refresh the LibreSCRS repository alone (its metadata from P1 has
# not expired yet; a failure in a repository that is not ours cannot be
# judged) and upgrade the packages P1 installed. The client must then hold the
# tree's signed index byte for byte, and each package must be, in the package
# database, at the newest version the tree names -- a tree with nothing newer
# (a re-sign) is green and says so. key also installs librecelik once more
# from the tree, so that its signature is checked by the key kept from the
# previous generation. On Ubuntu, apt's own report must show the tree's
# InRelease verified by the index subkey. A Fedora the tree has no rpm/<slug>/
# for must get rc 0 from dnf makecache and dnf upgrade and keep librecelik,
# under a dnf.conf that says skip_if_unavailable=False, so that only the
# release package's own skip_if_unavailable=True can keep it working.
#
# Exit codes: 0 green, 1 a finding, 2 cannot judge (the machine could not be
# prepared).
set -uo pipefail

V="${PROBE_APT_VERIFIER:-}"
me="$SLUG${V:+/$V}"
[ "$V" != gpgv ] || me="$SLUG"
say() { echo "probe[$me]: $*"; }
cannot() { say "$* -- cannot judge"; exit 2; }
finding() { say "::error::$*"; }

# shellcheck disable=SC2329  # called as "prepare_$MANAGER"
prepare_apt() {
    local tools=(wget gpg ca-certificates)
    [ "$V" != sqv ] || tools+=(sqv gpgv-sq)
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null || cannot "apt-get update"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${tools[@]}" >/dev/null || cannot "apt-get install ${tools[*]}"
    install -m 0644 /probe/ca.pem /usr/local/share/ca-certificates/librescrs-probe.crt || cannot "cannot install the CA"
    update-ca-certificates >/dev/null 2>&1 || cannot "update-ca-certificates"
    printf 'APT::Get::Assume-Yes "true";\n' >/etc/apt/apt.conf.d/99probe || cannot "cannot write 99probe"
    # On Ubuntu apt also reports which program verified which repository, so
    # P1's own output shows the LibreSCRS index verified by the chosen verifier.
    if [ "$SLUG" = ubuntu2604 ]; then
        printf 'Debug::Acquire::gpgv "1";\n' >>/etc/apt/apt.conf.d/99probe || cannot "cannot write 99probe"
    fi
    # Which program apt verifies a signature with, as apt itself reports it:
    # apt 3 on Ubuntu runs gpgv-sq when it is installed and gpgv otherwise, and
    # has no sqv method; Debian's apt verifies through its sqv method.
    if [ "$SLUG" = ubuntu2604 ]; then
        local v want=/usr/bin/gpgv
        [ "$V" != sqv ] || want=/usr/bin/gpgv-sq
        v="$(apt-get -o Debug::Acquire::gpgv=1 update 2>&1 | sed -n 's/^Preparing to exec: *\([^ ]*\) .*/\1/p' | sort -u)"
        [ "$v" = "$want" ] || cannot "apt verifies with '${v:-nothing}', not $want"
        say "apt verifies with $v"
    fi
}

# shellcheck disable=SC2329  # called as "prepare_$MANAGER"
prepare_dnf() {
    install -m 0644 /probe/ca.pem /etc/pki/ca-trust/source/anchors/librescrs-probe.pem || cannot "cannot install the CA"
    update-ca-trust || cannot "update-ca-trust"
    grep -q '^\[main\]' /etc/dnf/dnf.conf || cannot "/etc/dnf/dnf.conf has no [main]"
    sed -i '/^\[main\]/a assumeyes=True' /etc/dnf/dnf.conf || cannot "cannot write dnf.conf"
    grep -qx 'assumeyes=True' /etc/dnf/dnf.conf || cannot "assumeyes=True is not in dnf.conf"
}

# shellcheck disable=SC2329  # called as "prepare_$MANAGER"
prepare_zypper() {
    if [ "${PROBE_KEEP_IMAGE_DEFAULTS:-}" = 1 ]; then
        say "the image's no-recommends.conf is kept"
    else
        rm -f /usr/etc/zypp/zypp.conf.d/no-recommends.conf
        ! grep -rqsE '^[[:space:]]*solver\.onlyRequires[[:space:]]*=[[:space:]]*true' /etc/zypp /usr/etc/zypp \
            || cannot "solver.onlyRequires is still set"
    fi
    zypper -n -q install curl gpg2 >/dev/null || cannot "zypper install curl gpg2"
    install -m 0644 /probe/ca.pem /etc/pki/trust/anchors/librescrs-probe.pem || cannot "cannot install the CA"
    update-ca-certificates >/dev/null 2>&1 || cannot "update-ca-certificates"
    if [ "${PROBE_NO_ZYPPER_WRAPPER:-}" = 1 ]; then
        say "no zypper wrapper"
    else
        # first in PATH, and in sudo's secure_path where there is one
        { printf '#!/bin/sh\nexec /usr/bin/zypper --non-interactive "$@"\n' >/usr/local/sbin/zypper \
            && chmod 0755 /usr/local/sbin/zypper; } || cannot "cannot write the zypper wrapper"
        hash -r
        [ "$(command -v zypper)" = /usr/local/sbin/zypper ] || cannot "the zypper wrapper is not first in PATH"
    fi
}

installed() {
    case "$MANAGER" in
        apt) [ "$(dpkg-query -W -f '${db:Status-Status}' "$1" 2>/dev/null)" = installed ] ;;
        *)   rpm -q --quiet "$1" ;;
    esac
}

# p1_run -- the first-contact file, byte for byte as published; its rc in
# $P1_RC, its output in /tmp/p1.log
p1_run() {
    local d
    P1_RC=0
    command cp -f /probe/install.txt /tmp/i.sh
    [ "$(sha256sum </probe/install.txt)" = "$(sha256sum </tmp/i.sh)" ] || cannot "/tmp/i.sh is not the published text"
    d="$(mktemp -d /tmp/home.XXXXXX)"
    say "P1: $INSTALL"
    (cd "$d" && bash -euxo pipefail /tmp/i.sh </dev/null) 2>&1 | tee /tmp/p1.log || P1_RC=$?
}

p1() {
    p1_run
    if [ "$P1_RC" != 0 ]; then finding "P1: install/$INSTALL failed (rc $P1_RC)"; return 1; fi
    say "P1: install/$INSTALL ran to the end"
    [ "$SLUG" != ubuntu2604 ] || p1_verifier
}

# p1_verifier -- from apt's own report in P1: the LibreSCRS index was verified
# under its Signed-By keyring by the pass's verifier, with a valid signature by
# the index subkey (VALIDSIG's first field is the signing (sub)key)
p1_verifier() {
    local want=/usr/bin/gpgv
    [ "$V" != sqv ] || want=/usr/bin/gpgv-sq
    [ -n "${PROBE_INDEX_FPR:-}" ] || cannot "no PROBE_INDEX_FPR"
    if apt_verified "$want" "$PROBE_INDEX_FPR"; then
        say "P1: the LibreSCRS InRelease verified by $want (VALIDSIG $PROBE_INDEX_FPR)"
    else
        finding "P1: no LibreSCRS InRelease verified by $want with $PROBE_INDEX_FPR"
        return 1
    fi
}

# apt_verified EXE [FPR [LOG]] -- apt's own report in LOG (/tmp/p1.log) shows
# the LibreSCRS index checked under its Signed-By keyring by EXE (and, with
# FPR, a valid signature by FPR: VALIDSIG's first field is the signing (sub)key)
apt_verified() {
    awk -v exe="$1" -v fpr="${2:-}" '
        /^Trying Signed-By: / { ours = ($3 == "/usr/share/keyrings/librescrs-archive-keyring.pgp"); used = ""; next }
        ours && /^Preparing to exec:/ { used = $4; if (fpr == "" && used == exe) ok = 1 }
        ours && /^Got trusted VALIDSIG, key ID: / && fpr != "" && $NF == fpr && used == exe { ok = 1 }
        END { exit !ok }' "${3:-/tmp/p1.log}"
}

# forge_reason -- the client's own words for refusing this forgery, as
# measured: SEQ, EREs that must all be found in P1's output in this order.
# Together they name what the forgery broke, so that no other failure (the
# network, a timeout, another package, an index merely unsigned) passes for it.
forge_reason() {
    local ours='https://librescrs\.github\.io/packages' k="${PROBE_FORGE_KEY:-}"
    SEQ=()
    case "$MANAGER:$CLAIM" in
        apt:forge-a) SEQ=("Failed to fetch $ours/deb/pool/[a-z]+/librecelik_[^ ]+\.deb +Hash Sum mismatch") ;;
        # key B named first (gpgv and gpgv-sq: NO_PUBKEY <key id>; Debian's
        # sqv: Missing key <fingerprint>), then apt's refusal of the repository
        apt:forge-b) [[ "$k" =~ ^[0-9A-F]{40}$ ]] || return 1
                     SEQ=("NO_PUBKEY ${k:24}|Missing key $k, which is needed to verify signature"
                          "The repository '$ours/deb [a-z]+ InRelease' is not signed\.") ;;
        apt:forge-d) SEQ=("Release file for $ours/deb/dists/[a-z]+/InRelease is expired") ;;
        # the mismatch, then dnf giving up on librecelik because of it
        dnf:forge-a) SEQ=("Downloading successful, but checksum doesn't match"
                          "Librepo error: Cannot download librecelik-[^ ]+\.rpm: All mirrors were tried") ;;
        # dnf5 says this on every first contact, before it imports the .repo's
        # gpgkey; only after that import is it the refusal
        dnf:forge-b) SEQ=('^The key was successfully imported\.'
                          'repomd\.xml GPG signature verification error: Signing key not found') ;;
        dnf:forge-c) SEQ=('OpenPGP check for package "librecelik-[^"]+" .* has failed: The package is not signed\.') ;;
        # libzypp words it two ways, by how it fetched the package: against
        # the index's digest, or rpm's own check of the payload digest
        zypper:forge-a) if grep -q -E "Digest verification failed for file 'librecelik-" /tmp/p1.log; then
                            SEQ=("Digest verification failed for file 'librecelik-[^']+\.rpm'")
                        else
                            SEQ=('^librecelik-[^ ]+\.rpm:$' '^ +Payload SHA256 digest: BAD '
                                 'librecelik-[^ ]+ \(LibreSCRS\): Signature verification failed \[2-Signature does not verify\]')
                        fi ;;
        zypper:forge-b) [[ "$k" =~ ^[0-9A-F]{40}$ ]] || return 1
                        SEQ=("File 'repomd\.xml' from repository 'LibreSCRS' is signed with an unknown key '${k:24}'"
                             'Signature verification failed for repomd\.xml') ;;
        zypper:forge-c) SEQ=('librecelik-[^ ]+ \(LibreSCRS\): Signature verification failed \[6-File is unsigned\]') ;;
        *) return 1 ;;
    esac
}

# forge_match -- SEQ found in /tmp/p1.log in order; the lines in $MATCHED.
# grep and tail only: the Tumbleweed image has no awk.
forge_match() {
    local from=1 re hit
    MATCHED=""
    for re in "${SEQ[@]}"; do
        hit="$(tail -n "+$from" /tmp/p1.log | grep -n -m 1 -E -- "$re")" || return 1
        from=$((from + ${hit%%:*}))
        MATCHED+="${MATCHED:+ / }${hit#*:}"
    done
}

# forge -- P1 over a forged tree must fail, and for the forgery's reason
# (PROBE_FORGE_CLAIM, for the probe's self-test only: judge by another
# forgery's words)
forge() {
    CLAIM="${PROBE_FORGE_CLAIM:-$STEP}"
    case "$CLAIM" in forge-[abcd]) ;; *) cannot "unknown forgery '$CLAIM'" ;; esac
    p1_run
    if [ "$P1_RC" = 0 ]; then
        finding "$STEP: forgery installed: install/$INSTALL ran to the end"
        return 1
    fi
    if installed librecelik; then
        finding "$STEP: forgery installed: librecelik is installed although install/$INSTALL failed (rc $P1_RC)"
        return 1
    fi
    # only now: with the defect left out there is no key B to name
    forge_reason || cannot "no words for forgery $CLAIM on $MANAGER (key B: '${PROBE_FORGE_KEY:-}')"
    forge_match || {
        local w
        w="$(printf '/%s/ ' "${SEQ[@]}")"
        finding "$STEP: refused for the wrong reason: install/$INSTALL failed (rc $P1_RC) without, in this order, ${w% }; its last lines:"
        tail -n 25 /tmp/p1.log | sed 's/^/    | /'
        return 1
    }
    say "$STEP: refused: $MATCHED"
    if [ "$SLUG" = ubuntu2604 ]; then
        local exe=/usr/bin/gpgv
        [ "$V" != sqv ] || exe=/usr/bin/gpgv-sq
        apt_verified "$exe" || { finding "$STEP: the LibreSCRS InRelease was not checked by $exe"; return 1; }
        say "$STEP: the LibreSCRS InRelease was checked by $exe"
    fi
}

# version PACKAGE -- its installed version, from the package database (empty
# when it is not installed)
version() {
    installed "$1" || return 0
    case "$MANAGER" in
        apt) dpkg-query -W -f '${Version}' "$1" 2>/dev/null ;;
        *)   rpm -q --qf '%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}' "$1" 2>/dev/null ;;
    esac
}

# vercmp A B -- 0 when A = B, 1 when A > B, 2 when A < B, by the
# distribution's own comparison
vercmp() {
    local r
    case "$MANAGER" in
        apt) if dpkg --compare-versions "$1" eq "$2"; then return 0
             elif dpkg --compare-versions "$1" gt "$2"; then return 1; else return 2; fi ;;
        *)   r="$(rpm --eval "%{lua:print(rpm.vercmp('$1', '$2'))}")"
             case "$r" in 0) return 0 ;; 1) return 1 ;; -1) return 2 ;; *) cannot "rpm.vercmp('$1', '$2') is '$r'" ;; esac ;;
    esac
}

# newest PACKAGE -- the newest version of PACKAGE the tree names
newest() {
    local w best="" r
    for w in ${PROBE_TREE_VERSIONS:-}; do
        [ "${w%%=*}" = "$1" ] || continue
        r=0; [ -z "$best" ] || vercmp "${w#*=}" "$best" || r=$?
        [ -n "$best" ] && [ "$r" != 1 ] || best="${w#*=}"
    done
    echo "$best"
}

# foreign LOG -- the first line of LOG where a repository that is not
# LibreSCRS failed (its URL's host, or the name the manager gives it)
foreign() {
    local line w
    while IFS= read -r line; do
        while IFS= read -r w; do
            case "$w" in
                https://librescrs.github.io|'repository "librescrs"'|"Repository 'LibreSCRS'"|"files from 'LibreSCRS'"|'[librescrs|') ;;
                *) printf '%s\n' "$line"; return 0 ;;
            esac
        done < <(printf '%s\n' "$line" | grep -oE "https?://[^/ \"']+|repository \"[^\"]+\"|Repository '[^']+'|files from '[^']+'|\[[^]|]+\|")
    done < <(grep -E 'Failed to fetch|Failed to retrieve|Failed to download metadata|Status code: [0-9]+ for|Curl error|Download \(curl\) error|is invalid|Problem retrieving files from|Valid metadata not found|^Err:' "$1")
    return 1
}

# up CMD... -- one command of the upgrade, logged to /tmp/up.log; 1 with a
# finding (and the command's last lines) when it fails; cannot judge when what
# failed is a repository that is not LibreSCRS (a distribution mirror)
up() {
    local rc=0 line
    say "$P: $*"
    "$@" </dev/null 2>&1 | tee /tmp/up.cmd || rc=$?
    cat /tmp/up.cmd >>/tmp/up.log
    [ "$rc" = 0 ] && return 0
    if line="$(foreign /tmp/up.cmd)"; then
        cannot "$P: $* failed (rc $rc) in a repository that is not LibreSCRS: $line"
    fi
    finding "$P: $UPWHY$* failed (rc $rc); its last lines:"
    tail -n 25 /tmp/up.cmd | sed 's/^/    | /'
    return 1
}

# holds_index -- the client's own copy of the LibreSCRS index is the tree's,
# byte for byte. apt keeps "the previous index files" and exits 0 when the new
# InRelease does not verify; dnf with skip_if_unavailable keeps its cache.
holds_index() {
    local f got="" want="${PROBE_TREE_INDEX:-}" c
    local -a files=()
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || cannot "PROBE_TREE_INDEX '$want' is no sha256"
    shopt -s nullglob
    case "$MANAGER" in
        apt) case "$SLUG" in debian13) c=trixie ;; ubuntu2604) c=resolute ;; *) cannot "no codename for $SLUG" ;; esac
             files=(/var/lib/apt/lists/librescrs.github.io_packages_deb_dists_"${c}"_InRelease) ;;
        dnf) files=(/var/cache/libdnf5/librescrs-*/repodata/repomd.xml) ;;
        zypper) files=(/var/cache/zypp/raw/librescrs/repodata/repomd.xml) ;;
    esac
    shopt -u nullglob
    local seen=""
    for f in "${files[@]}"; do
        got="$(sha256sum <"$f")"; got="${got%% *}"
        if [ "$got" = "$want" ]; then say "$P: the client holds the tree's index ($f, sha256 $want)"; return 0; fi
        seen+="${seen:+, }$f is sha256 $got"
    done
    finding "$P: the client does not hold the tree's index (sha256 $want): ${seen:-no LibreSCRS index in its cache}"
    return 1
}

# generation -- upgrade (P3) or key (P5)
generation() {
    local p v w lib=librescrs-middleware keyring=librescrs-release bad=0
    # the host kills the pass PROBE_PASS_TIMEOUT seconds after it started; the
    # wait for the tree ends PROBE_SYNC_MARGIN seconds before that, which the
    # upgrade itself then has
    local limit=$(( ${PROBE_PASS_TIMEOUT:-1200} - ${PROBE_SYNC_MARGIN:-300} ))
    P=P3; [ "$STEP" = upgrade ] || P=P5
    UPWHY=""
    [ "$MANAGER" != apt ] || { lib=liblibrescrs5; keyring=librescrs-archive-keyring; }
    local -a pkgs=(librecelik librescrs-agent librescrs-pinentry-kde librescrs-card-plugins "$lib" "$keyring")
    local -A before=()
    say "$P: P1 against the previous generation"
    p1_run
    [ "$P1_RC" = 0 ] || cannot "$P: install/$INSTALL failed against the previous generation (rc $P1_RC)"
    for p in "${pkgs[@]}"; do
        before[$p]="$(version "$p")"
        [ -n "${before[$p]}" ] || cannot "$P: $p is not installed from the previous generation"
    done
    say "$P: from the previous generation: librecelik ${before[librecelik]}"
    : >/probe/sync/ready || cannot "cannot write /probe/sync/ready"
    while [ ! -e /probe/sync/go ]; do
        [ ! -e /probe/sync/abort ] || cannot "$P: the probe could not serve the tree"
        [ "$SECONDS" -lt "$limit" ] || cannot "$P: the tree was not served within ${limit}s of the pass's start"
        sleep 1
    done
    say "$P: the tree is served"
    : >/tmp/up.log
    if [ "${PROBE_TREE_GONE:-}" = 1 ]; then
        # a Fedora newer than the repository: fedora$releasever is a 404
        [ "$MANAGER" = dnf ] || cannot "the tree lacks $SLUG, which is no Fedora"
        UPWHY="rpm/$SLUG/ is not in the tree, and "
        # Fedora's own defaults (/usr/share/dnf5/libdnf.conf.d/
        # 20-fedora-defaults.conf) skip an unavailable repository, and so hide
        # what the release package says; a dnf.conf that turns that off (as a
        # user may) leaves only the repository's own skip_if_unavailable=True.
        # Fedora's own .repo files say skip_if_unavailable=False themselves.
        sed -i '/^\[main\]/a skip_if_unavailable=False' /etc/dnf/dnf.conf || cannot "cannot write dnf.conf"
        dnf --dump-main-config 2>/dev/null | grep -qx 'skip_if_unavailable = 0' \
            || cannot "skip_if_unavailable=False in dnf.conf does not take effect"
        say "$P: dnf.conf: skip_if_unavailable=False"
        up dnf makecache --refresh --repo=librescrs || return 1
        up dnf upgrade "${pkgs[@]}" || return 1
        v="$(version librecelik)"
        [ "$v" = "${before[librecelik]}" ] || { finding "$P: librecelik is '$v' after the upgrade, was ${before[librecelik]}"; return 1; }
        say "$P: rpm/$SLUG/ is not in the tree: dnf makecache and dnf upgrade rc 0, librecelik stays $v"
        return 0
    fi
    # the LibreSCRS repository, and only it, refreshed now: its metadata from
    # P1 has not expired, and the distribution's is not under test
    case "$MANAGER" in
        apt) mkdir -p /tmp/ours.d && command cp -f /etc/apt/sources.list.d/librescrs.sources /tmp/ours.d/ \
                 || cannot "no /etc/apt/sources.list.d/librescrs.sources"
             up apt-get update -o Dir::Etc::sourcelist=- -o Dir::Etc::sourceparts=/tmp/ours.d -o APT::Get::List-Cleanup=0 \
                 && up apt-get install --only-upgrade "${pkgs[@]}" ;;
        dnf) up dnf makecache --refresh --repo=librescrs && up dnf upgrade "${pkgs[@]}" ;;
        zypper) up zypper refresh librescrs && up zypper --no-refresh update "${pkgs[@]}" ;;
    esac || return 1
    if [ "$STEP" = key ]; then
        case "$MANAGER" in
            apt) up apt-get install --reinstall librecelik ;;
            dnf) up dnf reinstall librecelik ;;
            zypper) up zypper --no-refresh install --force librecelik ;;
        esac || return 1
    fi
    holds_index || bad=1
    if [ "$SLUG" = ubuntu2604 ]; then
        local exe=/usr/bin/gpgv
        [ "$V" != sqv ] || exe=/usr/bin/gpgv-sq
        if apt_verified "$exe" "$PROBE_INDEX_FPR" /tmp/up.log; then
            say "$P: the tree's InRelease verified by $exe (VALIDSIG $PROBE_INDEX_FPR)"
        else
            finding "$P: no LibreSCRS InRelease of the tree verified by $exe with $PROBE_INDEX_FPR"; bad=1
        fi
    fi
    for p in "${pkgs[@]}"; do
        w="$(newest "$p")" || cannot "$P: cannot compare the versions of $p"
        if [ -z "$w" ]; then finding "$P: the tree names no $p"; bad=1; continue; fi
        v="$(version "$p")"
        if [ -z "$v" ] || ! vercmp "$v" "$w"; then
            finding "$P: $p is ${v:-not installed} after the upgrade; the tree's newest is $w"; bad=1
        fi
    done
    [ "$bad" = 0 ] || return 1
    v="$(version librecelik)"
    w="$(newest librecelik)" || cannot "$P: cannot compare the versions of librecelik"
    if vercmp "$w" "${before[librecelik]}"; then
        # a re-sign, or a release of other packages: nothing to move to, and
        # what was judged is the refresh of the signed index
        say "$P: the tree has nothing newer than the published generation (librecelik $w); the upgrade refreshed the signed index"
    else
        say "$P: librecelik ${before[librecelik]} -> $v, the tree's newest (package database)"
    fi
}

p2() {
    local lib=librescrs-middleware p bad=0 rc=0
    [ "$MANAGER" != apt ] || lib=liblibrescrs5
    for p in librecelik librescrs-agent librescrs-pinentry-kde librescrs-card-plugins "$lib"; do
        if installed "$p"; then say "P2: $p installed"; else finding "P2: $p not installed"; bad=1; fi
    done
    [ "$SLUG" != opensusetw ] || { say "P2: no librekde on $SLUG (LibreKDE is not built for it)"; return "$bad"; }
    case "$MANAGER" in
        apt) apt-get install librekde </dev/null || rc=$? ;;
        dnf) dnf install librekde </dev/null || rc=$? ;;
    esac
    if [ "$rc" != 0 ]; then finding "P2: librekde does not install (rc $rc)"; return 1; fi
    for p in librekde librekde-common librekde-plasmoid librekde-kio librekde-purpose librekde-credentials; do
        if installed "$p"; then say "P2: $p installed"; else finding "P2: $p not installed (librekde)"; bad=1; fi
    done
    return "$bad"
}

case "$STEP" in
    p1p2|forge-[abcd]|upgrade|key) ;;
    *) cannot "unknown step '$STEP'" ;;
esac
case "$MANAGER" in
    apt|dnf|zypper) ;;
    *) cannot "unknown manager '$MANAGER'" ;;
esac
command -v sudo >/dev/null 2>&1 || {
    { printf '#!/bin/sh\nexec "$@"\n' >/usr/local/bin/sudo && chmod 0755 /usr/local/bin/sudo; } \
        || cannot "cannot write the sudo shim"
}
"prepare_$MANAGER"
if [ "$STEP" = upgrade ] || [ "$STEP" = key ]; then
    generation || exit 1
    say "$STEP green"
    exit 0
fi
if [ "$STEP" != p1p2 ]; then
    forge || exit 1
    say "$STEP green"
    exit 0
fi
p1 || exit 1
p2 || exit 1
say "p1p2 green"
exit 0
