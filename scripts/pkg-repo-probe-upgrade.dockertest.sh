#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (the probe installs packages in the distributions' own images)
# Self-test for pkg-repo-probe.sh's upgrade and key steps against real
# containers. Two generations of the fixture (pkg-repo-probe-fixture.sh): A,
# the code at 5.0.0 and the keyring packages at 1.0.0, and B, which adds the
# code at 5.1.0 and has the keyring packages at 1.1.0, assembled carrying A --
# both under the probe key.
#
# Cases: from A to B, the upgrade and the key steps are green on every slug,
# Ubuntu under each verifier, and A's signatures verify against B's KEY.asc --
# with A as assembled, and with A as pkg-repo.py fetch-prev mirrors it from a
# server (what a publish hands the probe), red when one stable alias is
# missing from that mirror;
# A signed again later (nothing newer: a weekly re-sign) is green and says so;
# without --prev, and with a --prev that fetch-prev found EMPTY, both are
# skipped (rc 0) and nothing starts; a --prev that is no mirror cannot be
# judged, and a foreign URL in install/arch.txt is a finding before anything
# starts; a Fedora the tree has no rpm/<slug>/ for is green, judged under a
# dnf.conf that says skip_if_unavailable=False (Fedora's own dnf5 defaults,
# /usr/share/dnf5/libdnf.conf.d/20-fedora-defaults.conf, skip, and would hide
# what the release package says). Red: B whose librecelik 5.1.0 depends on a
# package nothing provides (5.1.0 cannot be reached); B signed by new subkeys
# of the same primary, which A's certificate lacks (key, on every slug, each
# for its manager's reason), and A's own versions so signed (apt keeps its old
# index and exits 0); B's rpms (and, apart, A's) signed by a new rpm subkey
# under indexes by the old index subkey -- the rpm clients refuse the
# packages (rpm keeps its own copy of the key), apt is green; B's
# KEY.asc without the subkey A's rpms are signed by (A's old signatures); the
# Fedora without its tree from a release package without
# skip_if_unavailable=True.
#
# Network: the containers install from the distributions' mirrors.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ci="$(cd -- "$here/.." && pwd)"
probe="$here/pkg-repo-probe.sh"
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker is not on PATH -- cannot measure" >&2; exit 2; }
D13="$("$here/pkg-images" get debian13)" || exit 2
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-probe-up.XXXXXX")" || exit 2
tag="pkpr-up-$$"
kh=""
srv_pid=""
cleanup() {
    [ -z "$srv_pid" ] || { kill "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null; }
    if [ -n "$kh" ]; then
        GNUPGHOME="$kh" gpgconf --kill all >/dev/null 2>&1
        GNUPGHOME="$kh" gpgconf --remove-socketdir >/dev/null 2>&1
        rm -rf "$kh"
    fi
    docker ps -aq --filter "name=^$tag-" | xargs -r docker rm -f >/dev/null 2>&1
    rm -rf "$work" 2>/dev/null \
        || { timeout -k 10 120 docker run --rm -v "$work:/w" "$D13" find /w -mindepth 1 -delete >/dev/null 2>&1; rm -rf "$work"; }
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM
own="$(id -u):$(id -g)"
log="$work/log"

cases=0; red=0; fail=0
# expect NAME WANT GOT [TEXT] -- a red case counts only when the gate said 1,
# and TEXT (when given) must be in what the gate printed
expect() {
    cases=$((cases + 1))
    if [ "$2" = "$3" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" "$log"; }; then
        echo "ok   $1 (rc=$3)"; [ "$3" = 1 ] && red=$((red + 1))
        [ "$3" = 0 ] || grep -m 3 -e '::error::' -e 'cannot judge' "$log" | sed 's/^/       /'
    else
        echo "FAIL $1: want rc=$2${4:+ and \"$4\"}, got rc=$3"; tail -n 40 "$log" | sed 's/^/  | /'; fail=1
    fi
}
# check NAME COMMAND... -- one more case, ok when COMMAND succeeds
check() {
    local name="$1"; shift
    cases=$((cases + 1))
    if "$@"; then echo "ok   $name"
    else echo "FAIL $name"; grep -e '^pkg-repo-probe:' -e '::error::' "$log" | sed 's/^/  | /'; fail=1; fi
}
fatal() { echo "FATAL: $* -- cannot measure"; tail -n 40 "$log" | sed 's/^/  | /'; exit 2; }
# shellcheck source-path=SCRIPTDIR source=pkg-repo-probe-fixture.sh
. "$here/pkg-repo-probe-fixture.sh"

env_fpr() { sed -n "s/^$1=\([0-9A-F]\{40\}\)$/\1/p" "$2"; }
PRIMARY="$(env_fpr PACKAGE_FPR "$ci/keys/rehearsal.env")"
S_RPM="$(env_fpr S_RPM_FPR "$ci/keys/rehearsal.env")"
S_IDX="$(env_fpr S_IDX_FPR "$ci/keys/rehearsal.env")"
S_REZ="$(env_fpr S_REZ_FPR "$ci/keys/rehearsal.env")"
[ -n "$PRIMARY" ] && [ -n "$S_RPM" ] && [ -n "$S_IDX" ] && [ -n "$S_REZ" ] || fatal "keys/rehearsal.env is not four fingerprints"

# PKG_PROBE_DT_FIXTURE=<dir> keeps the fixture there and reuses it on the next
# run -- a development shortcut; CI never sets it, and a fixture kept from an
# older version of this test is not this test's fixture.
trees="${PKG_PROBE_DT_FIXTURE:-$work/trees}"
mkdir -p "$trees" || exit 2
names=(keys-y keys-y2 keys-z tree-a tree-a-noskip tree-b tree-bun tree-same tree-by tree-by2 tree-ay2 tree-b-nof44 tree-bz
       tree-ysame)
kept=1
for n in "${names[@]}"; do [ -e "$trees/$n" ] || kept=0; done
if [ -n "${PKG_PROBE_DT_FIXTURE:-}" ] && [ "$kept" = 1 ]; then
    echo "-- fixture: kept in $trees"
else
    for n in "${names[@]}"; do rm -rf "${trees:?}/$n"; done
    # --- the key sets ---------------------------------------------------------
    # Y: the probe key with two new signing subkeys, which sign B's rpms and
    # indexes; Y2: the same certificate, the first new subkey signing the rpms
    # and the probe key's own index subkey the indexes; Z: the probe
    # certificate without the subkey A's rpms are signed by. The secret part of
    # the probe key is public; this home is the test's.
    kh="$(mktemp -d /var/tmp/lg.XXXXXX)" || fatal "no GNUPGHOME"
    chmod 700 "$kh" || fatal "no GNUPGHOME"
    g() { GNUPGHOME="$kh" gpg --batch --no-tty --pinentry-mode loopback --passphrase '' "$@"; }
    fprs() { g --list-secret-keys --with-colons 2>/dev/null | sed -n 's/^fpr:\{9\}\([0-9A-F]\{40\}\):.*/\1/p' | LC_ALL=C sort; }
    g --import "$ci/keys/rehearsal.sec.asc" >"$log" 2>&1 || fatal "the probe key does not import"
    [ "$(fprs | tr '\n' ' ')" = "$(printf '%s\n' "$PRIMARY" "$S_RPM" "$S_IDX" "$S_REZ" | LC_ALL=C sort | tr '\n' ' ')" ] \
        || fatal "the test's GNUPGHOME holds other keys than the probe key"
    new=()
    for _ in 1 2; do
        old="$(fprs)"
        g --quick-add-key "$PRIMARY" ed25519 sign never >"$log" 2>&1 || fatal "cannot add a subkey"
        new+=("$(comm -13 <(echo "$old") <(fprs))")
    done
    [[ "${new[0]}" =~ ^[0-9A-F]{40}$ && "${new[1]}" =~ ^[0-9A-F]{40}$ ]] || fatal "the new subkeys are not two fingerprints"
    mkdir -p "$trees/keys-y" "$trees/keys-y2" "$trees/keys-z"
    g --armor --export "$PRIMARY" >"$trees/keys-y/rehearsal.asc" || fatal "no Y certificate"
    g --armor --export-secret-subkeys "${new[0]}!" "${new[1]}!" >"$trees/keys-y/rehearsal.sec.asc" || fatal "no Y secret"
    printf 'PACKAGE_FPR=%s\nS_RPM_FPR=%s\nS_IDX_FPR=%s\nS_REZ_FPR=%s\n' "$PRIMARY" "${new[0]}" "${new[1]}" "$S_REZ" \
        >"$trees/keys-y/rehearsal.env"
    command cp -f "$trees/keys-y/rehearsal.asc" "$trees/keys-y2/rehearsal.asc"
    g --armor --export-secret-subkeys "${new[0]}!" "$S_IDX!" >"$trees/keys-y2/rehearsal.sec.asc" || fatal "no Y2 secret"
    printf 'PACKAGE_FPR=%s\nS_RPM_FPR=%s\nS_IDX_FPR=%s\nS_REZ_FPR=%s\n' "$PRIMARY" "${new[0]}" "$S_IDX" "$S_REZ" \
        >"$trees/keys-y2/rehearsal.env"
    GNUPGHOME="$kh" gpg --armor --export --export-filter "drop-subkey=fpr = $S_RPM" "$PRIMARY" >"$trees/keys-z/rehearsal.asc" \
        || fatal "no Z certificate"
    command cp -f "$ci/keys/rehearsal.sec.asc" "$ci/keys/rehearsal.env" "$trees/keys-z/"
    GNUPGHOME="$kh" gpg --batch --show-keys --with-colons "$trees/keys-z/rehearsal.asc" 2>/dev/null | grep -q "^fpr:*$S_RPM:" \
        && fatal "Z still holds $S_RPM"
    GNUPGHOME="$kh" gpg --batch --show-keys --with-colons "$trees/keys-y/rehearsal.asc" 2>/dev/null | grep -q "^fpr:*${new[1]}:" \
        || fatal "Y does not hold ${new[1]}"
    GNUPGHOME="$kh" gpgconf --kill all >/dev/null 2>&1
    GNUPGHOME="$kh" gpgconf --remove-socketdir >/dev/null 2>&1
    rm -rf "$kh"; kh=""

    # --- the packages -----------------------------------------------------------
    fxa="$work/fx-a" fxb="$work/fx-b" fxby="$work/fx-by" fxby2="$work/fx-by2" fxay2="$work/fx-ay2"
    mkdir -p "$fxa" "$fxb"
    command cp -f "$ci/keys/rehearsal.asc" "$fxa/cert.asc"
    command cp -f "$ci/keys/rehearsal.asc" "$fxb/cert.asc"
    fx_packages "$fxa" 5.0.0 1.0.0 noskip
    fx_packages "$fxb" 5.1.0 1.1.0 unreach
    # still unsigned: B under Y and under Y2, A under Y2
    for c in "$fxb:$fxby" "$fxb:$fxby2" "$fxa:$fxay2"; do command cp -a "${c%%:*}" "${c#*:}" || fatal "no copy ${c#*:}"; done
    fx_ci "$work/ci-y" "$trees/keys-y"
    fx_ci "$work/ci-y2" "$trees/keys-y2"
    fx_sign "$ci" "$fxa"
    fx_sign "$ci" "$fxb"
    fx_sign "$work/ci-y" "$fxby"
    fx_sign "$work/ci-y2" "$fxby2"
    fx_sign "$work/ci-y2" "$fxay2"

    # --- the trees --------------------------------------------------------------
    fx_in "$work/in-a" "$fxa" 5.0.0 1.0.0 good
    fx_tree "$ci" "$work/in-a" "$trees/tree-a"
    fx_in "$work/in-a-noskip" "$fxa" 5.0.0 1.0.0 noskip
    fx_tree "$ci" "$work/in-a-noskip" "$trees/tree-a-noskip"
    fx_in "$work/in-b" "$fxa" 5.0.0 - good           # the publisher keeps two releases of the code
    fx_in "$work/in-b" "$fxb" 5.1.0 1.1.0 good
    fx_tree "$ci" "$work/in-b" "$trees/tree-b" "$trees/tree-a"
    fx_in "$work/in-bun" "$fxa" 5.0.0 - good         # B whose librecelik 5.1.0 cannot be installed
    fx_in "$work/in-bun" "$fxb" 5.1.0 1.1.0 unreach
    fx_tree "$ci" "$work/in-bun" "$trees/tree-bun" "$trees/tree-a"
    fx_in "$work/in-by2" "$fxby2" 5.1.0 1.1.0 good
    fx_tree "$work/ci-y2" "$work/in-by2" "$trees/tree-by2" "$trees/tree-a"
    fx_in "$work/in-ay2" "$fxay2" 5.0.0 1.0.0 good
    fx_tree "$work/ci-y2" "$work/in-ay2" "$trees/tree-ay2" "$trees/tree-a"
    fx_in "$work/in-same" "$fxa" 5.0.0 1.0.0 good    # A once more, signed again later
    fx_tree "$ci" "$work/in-same" "$trees/tree-same" "$trees/tree-a"
    fx_in "$work/in-by" "$fxby" 5.1.0 1.1.0 good
    fx_tree "$work/ci-y" "$work/in-by" "$trees/tree-by" "$trees/tree-a"
    # A's versions once more, the indexes signed by Y's new index subkey
    command cp -al "$trees/tree-same" "$trees/tree-ysame" || fatal "no copy of tree-same"
    for f in "$trees/tree-ysame/KEY.asc" "$trees"/tree-ysame/rpm/*/repodata/repomd.xml.key; do
        rm -f "$f"   # a link into tree-same: replaced, never written through
        command cp -f "$trees/keys-y/rehearsal.asc" "$f" || fatal "no $f"
    done
    python3 -I "$work/ci-y/scripts/pkg-repo.py" sign-index --tree "$trees/tree-ysame" --keyset rehearsal >"$log" 2>&1 \
        || fatal "sign-index of tree-ysame"
    cmp -s "$trees/tree-same/deb/dists/trixie/InRelease" "$trees/tree-ysame/deb/dists/trixie/InRelease" \
        && fatal "tree-ysame's InRelease is tree-same's"
    command cp -al "$trees/tree-b" "$trees/tree-b-nof44" || fatal "no copy of tree-b"
    rm -rf "${trees:?}/tree-b-nof44/rpm/fedora44"
    command cp -al "$trees/tree-b" "$trees/tree-bz" || fatal "no copy of tree-b"
    rm -f "$trees/tree-bz/KEY.asc"   # a link into tree-b: replaced, never written through
    command cp -f "$trees/keys-z/rehearsal.asc" "$trees/tree-bz/KEY.asc" || fatal "no KEY.asc for tree-bz"

    pk="$trees/tree-b/deb/dists/trixie/main/binary-amd64/Packages"
    if ! grep -q '^Version: 5.1.0-1~deb13$' "$pk" || ! grep -q '^Version: 5.0.0-1~deb13$' "$pk"; then
        fatal "tree-b does not index both releases of the code"
    fi
    ! grep -q '5\.1\.0' "$trees/tree-same/deb/dists/trixie/main/binary-amd64/Packages" || fatal "tree-same has 5.1.0"
    cmp -s "$trees/tree-a/deb/dists/trixie/InRelease" "$trees/tree-same/deb/dists/trixie/InRelease" \
        && fatal "tree-same is tree-a, not signed again"
    cmp -s "$trees/tree-by/KEY.asc" "$trees/keys-y/rehearsal.asc" || fatal "tree-by's KEY.asc is not Y"
    [ -d "$trees/tree-b-nof44/rpm/fedora43" ] && [ ! -e "$trees/tree-b-nof44/rpm/fedora44" ] || fatal "tree-b-nof44"
    [ -f "$trees/tree-a-noskip/rpm/fedora44/librescrs-release-1.0.0-1.fc44.noarch.rpm" ] || fatal "no release package in tree-a-noskip"
    cmp -s "$trees/tree-a/librescrs-release-fedora.noarch.rpm" "$trees/tree-a-noskip/librescrs-release-fedora.noarch.rpm" \
        && fatal "tree-a-noskip has the release package with skip_if_unavailable"
fi
# the same scripts under the key sets Y and Z (copied on every run: the code
# under test is this checkout's)
fx_ci "$work/ci-y" "$trees/keys-y"
fx_ci "$work/ci-y2" "$trees/keys-y2"
fx_ci "$work/ci-z" "$trees/keys-z"

inst="$work/install"
fx_install "$inst"

# PKG_PROBE_DT_LOGS=<dir> keeps every probe run's output there, numbered (a
# development aid, as PKG_PROBE_DT_FIXTURE)
runs=0
probe_run() {  # probe_run [PROBE] -- ARGS...: the probe's rc in $rc, its output in $log
    local p="$probe"
    [ "$1" = -- ] || { p="$1"; shift; }
    shift
    rc=0
    "$p" --install-dir "${INST:-$inst}" --keyset rehearsal "$@" >"$log" 2>&1 || rc=$?
    runs=$((runs + 1))
    [ -z "${PKG_PROBE_DT_LOGS:-}" ] || command cp -f "$log" "$PKG_PROBE_DT_LOGS/run$runs.log"
}
# lines REGEX -- how many lines of the log match
lines() { grep -cE -- "$1" "$log"; }
nothing_started() { ! grep -q -e 'serving' -e '^-- ' -e 'probe\[' "$log"; }

# unreached -- tree-bun: red on each slug because librecelik 5.1.0 cannot be
# installed: apt and zypper refuse the upgrade in their own words; dnf skips
# the candidate with rc 0, and the probe's newest-version check is what is red
unreached() {
    [ "$(lines '^pkg-repo-probe: (debian13|fedora44|opensusetw): upgrade red$')" = 3 ] \
        && grep -q '^probe\[debian13\]: ::error::P3: apt-get install --only-upgrade .* failed (rc 100)' "$log" \
        && grep -qF ' librecelik : Depends: librescrs-nothing-provides (>= 5.0) but it is not installable' "$log" \
        && grep -q '^probe\[fedora44\]: ::error::P3: librecelik is 5\.0\.0-1\.fc44 after the upgrade; the tree.s newest is 5\.1\.0-1\.fc44$' "$log" \
        && grep -qF 'nothing provides librescrs-nothing-provides >= 5.0 needed by librecelik-5.1.0-1.fc44.x86_64 from librescrs' "$log" \
        && grep -q '^probe\[opensusetw\]: ::error::P3: zypper --no-refresh update .* failed (rc 4)' "$log" \
        && grep -qF "nothing provides 'librescrs-nothing-provides >= 5.0' needed by the to be installed librecelik-5.1.0-1.x86_64" "$log"
}
# y_reasons -- tree-by: apt keeps its old index, dnf has no librecelik to
# install again, zypper refuses the index
y_reasons() {
    [ "$(lines "^probe\[(debian13|ubuntu2604|ubuntu2604/sqv)\]: ::error::P5: the client does not hold the tree's index ")" = 3 ] \
        && [ "$(lines '^probe\[(fedora43|fedora44)\]: ::error::P5: dnf reinstall librecelik failed ')" = 2 ] \
        && [ "$(lines '^probe\[opensusetw\]: ::error::P5: zypper refresh librescrs failed ')" = 1 ]
}
# by2_reasons -- tree-by2: debian13 green (apt trusts the index, the debs
# are not signed); dnf and zypper refuse the upgrade on the packages' signature
by2_reasons() {
    [ "$(lines '^pkg-repo-probe: debian13: key green$'):$(lines '^pkg-repo-probe: (fedora44|opensusetw): key red$')" = "1:2" ] \
        && grep -q '^probe\[fedora44\]: ::error::P5: dnf upgrade .* failed (rc 1)' "$log" \
        && grep -qF 'OpenPGP check for package "librecelik-5.1.0-1.fc44.x86_64"' "$log" \
        && grep -qF "has failed: Import of the key didn't help, wrong key?" "$log" \
        && grep -q '^probe\[opensusetw\]: ::error::P5: zypper --no-refresh update .* failed (rc 8)' "$log" \
        && grep -qF '(LibreSCRS): Signature verification failed [4-Signatures public key is not available]' "$log"
}
# ay2_reasons -- tree-ay2, nothing to upgrade: on fedora43 and opensusetw only
# the key step's second install of librecelik meets its new signature
ay2_reasons() {
    [ "$(lines '^pkg-repo-probe: debian13: key green$'):$(lines '^pkg-repo-probe: (fedora43|opensusetw): key red$')" = "1:2" ] \
        && grep -q '^probe\[fedora43\]: ::error::P5: dnf reinstall librecelik failed (rc 1)' "$log" \
        && grep -qF 'OpenPGP check for package "librecelik-5.0.0-1.fc43.x86_64"' "$log" \
        && grep -q '^probe\[opensusetw\]: ::error::P5: zypper --no-refresh install --force librecelik failed (rc 8)' "$log" \
        && grep -qF 'librecelik-5.0.0-1.x86_64 (LibreSCRS): Signature verification failed [4-Signatures public key is not available]' "$log"
}

# --- 1. no published generation --------------------------------------------------
probe_run -- --tree "$trees/tree-b" --steps "upgrade key"
expect "without --prev, P3 and P5 are skipped" 0 "$rc" "P3/P5 skipped: no published generation (no --prev)"
check "...and nothing starts" nothing_started
mkdir -p "$work/empty"
echo "https://librescrs.github.io/packages/deb/dists/trixie/InRelease is HTTP 404: no published generation" >"$work/empty/EMPTY"
probe_run -- --tree "$trees/tree-b" --prev "$work/empty" --steps "upgrade key"
expect "with an EMPTY --prev, P3 and P5 are skipped and say why" 0 "$rc" \
    "P3/P5 skipped: no published generation (https://librescrs.github.io/packages/deb/dists/trixie/InRelease is HTTP 404: no published generation)"
check "...and nothing starts" nothing_started
mkdir -p "$work/junk" && echo x >"$work/junk/x"
probe_run -- --tree "$trees/tree-b" --prev "$work/junk" --steps upgrade
expect "a --prev that is no mirror cannot be judged" 2 "$rc" "is neither a mirror"
# Arch is not probed, but the site quotes install/arch.txt: its URLs are judged.
badarch="$work/install-badarch"; command cp -rf "$inst" "$badarch"
sed -i 's|^curl -fLO https://librescrs.github.io/packages/KEYS$|curl -fLO https://librescrs.example.org/KEYS|' "$badarch/arch.txt"
grep -q 'example.org' "$badarch/arch.txt" || fatal "the perturbation did not change arch.txt"
INST="$badarch" probe_run -- --tree "$trees/tree-b" --prev "$trees/tree-a" --steps upgrade --slugs debian13
expect "RED a URL outside https://librescrs.github.io/packages/ in arch.txt" 1 "$rc" \
    "arch.txt: https://librescrs.example.org/KEYS is not under"
check "...before the server or any client runs" nothing_started

# --- 2. from A to B -----------------------------------------------------------------
probe_run -- --tree "$trees/tree-b" --prev "$trees/tree-a" --steps "upgrade key"
expect "P3 and P5 from A to B on every slug, Ubuntu under each verifier" 0 "$rc"
passes="debian13 ubuntu2604 ubuntu2604/sqv fedora43 fedora44 opensusetw"
verdicts() {
    local p s want=""
    for s in upgrade key; do for p in $passes; do want+="pkg-repo-probe: $p: $s green"$'\n'; done; done
    [ "$(grep -E '^pkg-repo-probe: [a-z0-9/]+: (upgrade|key) ' "$log" | LC_ALL=C sort)" = "$(printf '%s' "$want" | LC_ALL=C sort)" ]
}
check "...the twelve passes green" verdicts
moved() {
    [ "$(lines '^probe\[(debian13|ubuntu2604|ubuntu2604/sqv)\]: P[35]: librecelik 5\.0\.0-1~(deb13|ubuntu26\.04) -> 5\.1\.0-1~(deb13|ubuntu26\.04), the tree.s newest \(package database\)$')" = 6 ] \
        && [ "$(lines '^probe\[(fedora43|fedora44)\]: P[35]: librecelik 5\.0\.0-1\.fc4[34] -> 5\.1\.0-1\.fc4[34], the tree.s newest \(package database\)$')" = 4 ] \
        && [ "$(lines '^probe\[opensusetw\]: P[35]: librecelik 5\.0\.0-1 -> 5\.1\.0-1, the tree.s newest \(package database\)$')" = 2 ]
}
check "...librecelik 5.0.0 -> 5.1.0 in each, read from the package database" moved
check "...and Ubuntu's apt verified B's InRelease by the index subkey after the swap" \
    test "$(lines "^probe\[ubuntu2604\]: P[35]: the tree's InRelease verified by /usr/bin/gpgv \(VALIDSIG $S_IDX\)$|^probe\[ubuntu2604/sqv\]: P[35]: the tree's InRelease verified by /usr/bin/gpgv-sq \(VALIDSIG $S_IDX\)$")" = 4
check "...and A's signatures verify against B's KEY.asc" \
    grep -q "^pkg-repo-probe: key: the previous generation's signatures verify against the tree's KEY.asc$" "$log"

# --- 2b. from A to B, A as fetch-prev mirrors it ----------------------------------------
# A publish hands the probe what pkg-repo.py fetch-prev mirrored from the live
# site, not an assembled tree: tree A served over HTTP and mirrored here.
srvlog="$work/http.log"
python3 -I -u -m http.server --bind 127.0.0.1 --directory "$trees/tree-a" 0 >"$srvlog" 2>&1 &
srv_pid=$!
port=""
for _ in $(seq 1 50); do
    port="$(sed -n 's/^Serving HTTP on .* port \([0-9]\{1,5\}\) .*/\1/p' "$srvlog")"
    [ -n "$port" ] && break
    sleep 0.2
done
[ -n "$port" ] || fatal "the HTTP server serving tree-a did not start"
rc=0
python3 -I "$here/pkg-repo.py" fetch-prev --url "http://127.0.0.1:$port" --keyset rehearsal --out "$work/prev-a" \
    >"$log" 2>&1 || rc=$?
kill "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null; srv_pid=""
expect "fetch-prev mirrors A from the server" 0 "$rc" "verified files of the previous generation"
mirrored() {
    local n
    for n in librescrs-archive-keyring-trixie.deb librescrs-archive-keyring-resolute.deb \
             librescrs-release-fedora.noarch.rpm librescrs-release-opensusetw.noarch.rpm KEYS KEY.asc; do
        cmp -s "$trees/tree-a/$n" "$work/prev-a/$n" || return 1
    done
}
check "...with the four stable aliases, KEYS and KEY.asc as the site serves them" mirrored
probe_run -- --tree "$trees/tree-b" --prev "$work/prev-a" --steps "upgrade key"
expect "P3 and P5 from the fetch-prev mirror of A to B on every slug" 0 "$rc"
check "...the twelve passes green" verdicts
check "...librecelik 5.0.0 -> 5.1.0 in each" moved
command cp -al "$work/prev-a" "$work/prev-a-noalias" || fatal "no copy of the mirror"
rm -f "$work/prev-a-noalias/librescrs-archive-keyring-trixie.deb"
probe_run -- --tree "$trees/tree-b" --prev "$work/prev-a-noalias" --steps upgrade --slugs debian13
expect "RED the mirror without the trixie keyring alias: install/debian13.txt fails against it" 2 "$rc" \
    "P3: install/debian13.txt failed against the previous generation"

# --- 3. nothing newer, and a newer librecelik that cannot be reached ---------------------
probe_run -- --tree "$trees/tree-same" --prev "$trees/tree-a" --steps upgrade --slugs "debian13 fedora44"
expect "A signed again later (nothing newer: a weekly re-sign) is green" 0 "$rc"
check "...and says why, on both slugs" \
    test "$(lines "^probe\[(debian13|fedora44)\]: P3: the tree has nothing newer than the published generation \(librecelik 5\.0\.0-1(~deb13|\.fc44)\); the upgrade refreshed the signed index$")" = 2
check "...after taking the tree's index" test "$(lines "^probe\[(debian13|fedora44)\]: P3: the client holds the tree's index ")" = 2

probe_run -- --tree "$trees/tree-bun" --prev "$trees/tree-a" --steps upgrade --slugs "debian13 fedora44 opensusetw"
expect "RED librecelik 5.1.0 in the tree depends on a package nothing provides" 1 "$rc" "librecelik"
check "...red on each slug, each in its manager's words for the dependency nothing provides" unreached

# --- 4. B signed by subkeys A's certificate lacks -------------------------------------
probe_run "$work/ci-y/scripts/pkg-repo-probe.sh" -- --tree "$trees/tree-by" --prev "$trees/tree-a" --steps key
expect "RED B signed by new subkeys of the same primary, which A's certificate lacks" 1 "$rc" "::error::P5:"
check "...red on every slug, apt and rpm" \
    test "$(lines '^pkg-repo-probe: (debian13|ubuntu2604|ubuntu2604/sqv|fedora43|fedora44|opensusetw): key red$')" = 6
check "...each for its manager's reason" y_reasons

probe_run "$work/ci-y/scripts/pkg-repo-probe.sh" -- --tree "$trees/tree-ysame" --prev "$trees/tree-a" --steps key --slugs debian13
expect "RED A's versions, the indexes signed by a subkey A's certificate lacks (apt keeps the old index, rc 0)" 1 "$rc" \
    "probe[debian13]: ::error::P5: the client does not hold the tree's index"
check "...the only finding of the client" \
    test "$(lines '^probe\[debian13\]: ::error::'):$(lines '^pkg-repo-probe: debian13: key red$')" = "1:1"

# --- 4b. the rpms signed by a subkey A's certificate lacks, the indexes as before ---------
probe_run "$work/ci-y2/scripts/pkg-repo-probe.sh" -- --tree "$trees/tree-by2" --prev "$trees/tree-a" --steps key \
    --slugs "debian13 fedora44 opensusetw"
expect "RED B's rpms signed by a new rpm subkey, the indexes by the old index subkey" 1 "$rc" "::error::P5:"
check "...the rpm clients refuse the packages' signature; apt, which trusts the index, is green" by2_reasons
# fedora43: the release package P1 installed is that index's own (the stable alias is
# the fedora43 build), so nothing at all is upgraded there
probe_run "$work/ci-y2/scripts/pkg-repo-probe.sh" -- --tree "$trees/tree-ay2" --prev "$trees/tree-a" --steps key \
    --slugs "debian13 fedora43 opensusetw"
expect "RED the same at A's versions: only installing librecelik again meets the new signature" 1 "$rc" "::error::P5:"
check "...the rpm clients refuse it on that install; apt is green" ay2_reasons

# --- 5. B's KEY.asc without the subkey A's rpms are signed by ---------------------------
probe_run "$work/ci-z/scripts/pkg-repo-probe.sh" -- --tree "$trees/tree-bz" --prev "$trees/tree-a" --steps key --slugs debian13
expect "RED B's KEY.asc without the subkey A's rpms are signed by" 1 "$rc" \
    "::error::P5: the previous generation's rpms: rpm signatures not verified"
check "...A's old signatures are what is red; the client is green" \
    test "$(lines '^pkg-repo-probe: key: old signatures red$'):$(lines '^pkg-repo-probe: debian13: key green$')" = "1:1"

# --- 6. a Fedora the tree has no rpm/<slug>/ for -----------------------------------------
probe_run -- --tree "$trees/tree-b-nof44" --prev "$trees/tree-a" --steps upgrade --slugs fedora44
expect "fedora44 without rpm/fedora44/ in the tree upgrades with rc 0" 0 "$rc" \
    "P3: rpm/fedora44/ is not in the tree: dnf makecache and dnf upgrade rc 0"
check "...under a dnf.conf that says skip_if_unavailable=False: the release package's flag wins" \
    grep -q '^probe\[fedora44\]: P3: dnf.conf: skip_if_unavailable=False$' "$log"
probe_run -- --tree "$trees/tree-b-nof44" --prev "$trees/tree-a-noskip" --steps upgrade --slugs fedora44
expect "RED the same from a release package without skip_if_unavailable=True" 1 "$rc" \
    "::error::P3: rpm/fedora44/ is not in the tree, and dnf makecache --refresh --repo=librescrs failed"

left="$(docker ps -aq --filter 'name=^probe-' | wc -l) $(docker network ls -q --filter 'name=^probe-' | wc -l)"
cases=$((cases + 1))
if [ "$left" = "0 0" ]; then echo "ok   no probe container or network is left"
else echo "FAIL left behind (containers, networks): $left"; fail=1; fi

echo "selftest: $cases cases, $red red-proved"
[ "$fail" = 0 ]
