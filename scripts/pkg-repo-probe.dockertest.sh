#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (the probe installs packages in the distributions' own images)
# Self-test for pkg-repo-probe.sh against real containers: a fixture with the
# real package names and the same Depends/Recommends as the published chain
# (debs built in the debian13 image, rpms in each rpm slug's image and signed
# with the public rehearsal key), keyring packages built like the packages
# repository's, the first-contact texts of install/*.txt, and a tree made by
# pkg-repo.py assemble + sign-index.
#
# Cases: the first-contact commands and the installation on every slug, Ubuntu
# also under the Sequoia verifier (gpgv-sq, as apt's own P1 output shows), are
# green; red: a librecelik without its Recommends, the Tumbleweed image's
# no-recommends default kept, a foreign URL in install/fedora.txt, a host or an
# IP address without a scheme, zypper without the non-interactive wrapper
# (failing on its prompt), a pass over its deadline (cannot judge), a tree
# without librekde on fedora44 (but not on opensusetw, which has no LibreKDE);
# the server's /swap replaces the served tree, and refuses a tree it does not
# hold. P4: every forgery is refused on every slug it applies to, each for its
# own reason, and the tree it was made from is unchanged; red: the same steps
# with the defect left out (PROBE_FORGE_NOOP=1), and an unsigned rpm on
# opensusetw from a release package without pkg_gpgcheck=1, a forgery judged
# by another forgery's words; a step after the forgeries is judged on the tree
# itself; forgeries for a tree under another key than the probe key, and a
# PROBE_FORGE_JOBS that is no positive integer, cannot be judged.
#
# Network: the containers install from the distributions' mirrors.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ci="$(cd -- "$here/.." && pwd)"
probe="$here/pkg-repo-probe.sh"
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker is not on PATH -- cannot measure" >&2; exit 2; }
D13="$("$here/pkg-images" get debian13)" || exit 2
work="$(mktemp -d "${TMPDIR:-/var/tmp}/pkg-probe-dt.XXXXXX")" || exit 2
tag="pkpr-dt-$$"
cleanup() {
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
fatal() { echo "FATAL: $* -- cannot measure"; tail -n 40 "$log" | sed 's/^/  | /'; exit 2; }

# --- fixture ------------------------------------------------------------------
# shellcheck source-path=SCRIPTDIR source=pkg-repo-probe-fixture.sh
. "$here/pkg-repo-probe-fixture.sh"
fx="$work/fx"; mkdir -p "$fx"
# the keyring packages carry the rehearsal certificate, exactly as a rehearsal
# of the packages repository builds them
command cp -f "$ci/keys/rehearsal.asc" "$fx/cert.asc"

# PKG_PROBE_DT_FIXTURE=<dir> keeps the trees there and reuses them on the next
# run -- a development shortcut; CI never sets it, and a tree kept from an
# older version of this test is not this test's fixture.
trees="${PKG_PROBE_DT_FIXTURE:-$work/trees}"
mkdir -p "$trees" || exit 2
if [ -n "${PKG_PROBE_DT_FIXTURE:-}" ] && [ -d "$trees/tree-good" ] && [ -d "$trees/tree-norec" ] && [ -d "$trees/tree-nokde" ] \
    && [ -d "$trees/tree-nopkgcheck" ]; then
    echo "-- fixture: the trees kept in $trees"
else
    fx_packages "$fx" 5.0.0 1.0.0 norec nopkgcheck
    fx_sign "$ci" "$fx"
    # tree NAME -- the tree of variant NAME: good | norec (librecelik without
    # Recommends) | nokde (no librekde metapackage) | nopkgcheck (the
    # opensusetw release package without pkg_gpgcheck=1)
    tree() {
        fx_in "$work/in-$1" "$fx" 5.0.0 1.0.0 "$1"
        fx_tree "$ci" "$work/in-$1" "$trees/tree-$1"
    }
    tree good
    tree norec
    tree nokde
    tree nopkgcheck
    cmp -s "$trees/tree-good/librescrs-release-opensusetw.noarch.rpm" \
        "$trees/tree-nopkgcheck/librescrs-release-opensusetw.noarch.rpm" \
        && fatal "the nopkgcheck tree has the good release package"
    [ -f "$trees/tree-norec/deb/pool/trixie/librecelik_5.0.0-1.deb13_amd64.deb" ] || fatal "no librecelik in the norec tree"
    ls "$trees"/tree-nokde/rpm/fedora44/librekde-5* >/dev/null 2>&1 && fatal "the nokde tree has librekde"
    ls "$trees"/tree-good/rpm/fedora44/librekde-5* >/dev/null 2>&1 || fatal "the good tree has no librekde"
fi

inst="$work/install"
fx_install "$inst"

probe_run() {  # probe_run TREE [args...] -- the probe's rc in $rc, its output in $log
    local t="$1"; shift
    rc=0
    "$probe" --tree "$trees/tree-$t" --install-dir "${INST:-$inst}" --keyset rehearsal "$@" >"$log" 2>&1 || rc=$?
}

# --- 1. every slug, Ubuntu twice ----------------------------------------------
probe_run good
expect "P1+P2 on every slug and Ubuntu under sqv" 0 "$rc"
cases=$((cases + 1))
if [ "$(grep -cE '^pkg-repo-probe: (debian13|ubuntu2604|ubuntu2604/sqv|fedora43|fedora44|opensusetw): p1p2 green$' "$log")" = 6 ]; then
    echo "ok   ...and the verdict names six green passes"
else
    echo "FAIL the verdict does not name six green passes"; grep '^pkg-repo-probe:' "$log" | sed 's/^/  | /'; fail=1
fi
cases=$((cases + 1))
if grep -q 'probe\[ubuntu2604/sqv\]: apt verifies with /usr/bin/gpgv-sq' "$log" \
    && grep -q 'probe\[ubuntu2604\]: apt verifies with /usr/bin/gpgv$' "$log"; then
    echo "ok   ...and Ubuntu was measured under each verifier"
else
    echo "FAIL Ubuntu's verifier is not measured"; grep 'verifies with' "$log" | sed 's/^/  | /'; fail=1
fi
idx="$(sed -n 's/^S_IDX_FPR=//p' "$ci/keys/rehearsal.env")"
cases=$((cases + 1))
if grep -q "^probe\[ubuntu2604/sqv\]: P1: the LibreSCRS InRelease verified by /usr/bin/gpgv-sq (VALIDSIG $idx)$" "$log" \
    && grep -q "^probe\[ubuntu2604\]: P1: the LibreSCRS InRelease verified by /usr/bin/gpgv (VALIDSIG $idx)$" "$log"; then
    echo "ok   ...and P1's own apt output shows the LibreSCRS InRelease verified by each"
else
    echo "FAIL P1 does not show the LibreSCRS InRelease verified by each verifier"; grep 'InRelease' "$log" | sed 's/^/  | /'; fail=1
fi

# --- 2. librecelik without Recommends -----------------------------------------
probe_run norec --slugs "debian13 fedora44"
expect "RED librecelik without Recommends" 1 "$rc" "librescrs-agent not installed"
cases=$((cases + 1))
if [ "$(grep -c '^pkg-repo-probe: \(debian13\|fedora44\): p1p2 red$' "$log")" = 2 ]; then
    echo "ok   ...on both slugs"
else echo "FAIL not red on both slugs"; grep '^pkg-repo-probe:' "$log" | sed 's/^/  | /'; fail=1; fi

# --- 3. the Tumbleweed image's no-recommends default kept ----------------------
PROBE_KEEP_IMAGE_DEFAULTS=1 probe_run good --slugs opensusetw
expect "RED opensusetw with the image's no-recommends.conf kept" 1 "$rc" "librescrs-agent not installed"

# --- 4. a foreign URL in install/fedora.txt ------------------------------------
bad="$work/install-badurl"; command cp -rf "$inst" "$bad"
sed -i 's|https://librescrs.github.io/packages/librescrs-release-fedora|https://librescrs.example.org/packages/librescrs-release-fedora|' "$bad/fedora.txt"
grep -q 'example.org' "$bad/fedora.txt" || fatal "the perturbation did not change fedora.txt"
INST="$bad" probe_run good --slugs fedora43
expect "RED a URL outside https://librescrs.github.io/packages/ in fedora.txt" 1 "$rc" \
    "fedora.txt: https://librescrs.example.org/packages/librescrs-release-fedora.noarch.rpm is not under"
cases=$((cases + 1))
if [ "$rc" = 1 ] && ! grep -q -e 'probe\[' -e '^-- ' -e 'serving' "$log"; then echo "ok   ...before the server or any client runs"
else echo "FAIL the foreign URL was not judged before the server and the clients"; fail=1; fi

# --- 5. zypper without the wrapper ---------------------------------------------
PROBE_NO_ZYPPER_WRAPPER=1 probe_run good --slugs opensusetw
expect "RED opensusetw without the zypper wrapper fails P1" 1 "$rc" "P1: install/opensusetw.txt failed"
cases=$((cases + 1))
if grep -q 'Cannot read input: bad stream or EOF' "$log"; then echo "ok   ...because zypper could not read an answer to its prompt"
else echo "FAIL P1 did not fail on zypper's prompt"; tail -n 20 "$log" | sed 's/^/  | /'; fail=1; fi

# --- 5b. a place without a scheme: wget host/..., curl IP/... -------------------
bad2="$work/install-noscheme"; command cp -rf "$inst" "$bad2"
sed -i 's|^wget https://librescrs.github.io/packages/|wget librescrs.example.org/packages/|' "$bad2/debian13.txt"
sed -i 's|^curl -fLO https://librescrs.github.io/packages/KEY.asc|curl -fLO 192.0.2.1/KEY.asc|' "$bad2/opensusetw.txt"
{ grep -q '^wget librescrs.example.org/' "$bad2/debian13.txt" && grep -q '^curl -fLO 192.0.2.1/' "$bad2/opensusetw.txt"; } \
    || fatal "the perturbation did not change debian13.txt and opensusetw.txt"
INST="$bad2" probe_run good --slugs "debian13 opensusetw"
expect "RED wget of a host without a scheme in debian13.txt" 1 "$rc" \
    "debian13.txt: librescrs.example.org/packages/librescrs-archive-keyring-trixie.deb is not under"
expect "RED curl of an IP address in opensusetw.txt" 1 "$rc" "opensusetw.txt: 192.0.2.1/KEY.asc is not under"

# --- 6. no librekde -----------------------------------------------------------
probe_run nokde --slugs "fedora44 opensusetw"
expect "RED a tree without librekde on fedora44" 1 "$rc" "librekde does not install"
cases=$((cases + 1))
if grep -q '^pkg-repo-probe: opensusetw: p1p2 green$' "$log" && grep -q '^pkg-repo-probe: fedora44: p1p2 red$' "$log"; then
    echo "ok   ...while opensusetw, which has no LibreKDE, is green"
else echo "FAIL opensusetw is not green on the nokde tree"; grep '^pkg-repo-probe:' "$log" | sed 's/^/  | /'; fail=1; fi

# --- 7. P4, forgeries -----------------------------------------------------------
# verdicts LOG -- the forge verdict lines of LOG, sorted
verdicts() { grep -E '^pkg-repo-probe: [a-z0-9/]+: forge-[abcd] ' "$1" | LC_ALL=C sort; }
sha_tree() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum; }
before="$(sha_tree "$trees/tree-good")"
probe_run good --steps forge
expect "P4: every forgery refused, for its reason, on every slug it applies to" 0 "$rc"
want=""
for p in debian13 ubuntu2604 ubuntu2604/sqv fedora43 fedora44 opensusetw; do want+="pkg-repo-probe: $p: forge-a green"$'\n'; done
for p in debian13 ubuntu2604 ubuntu2604/sqv fedora43 fedora44 opensusetw; do want+="pkg-repo-probe: $p: forge-b green"$'\n'; done
for p in fedora43 fedora44 opensusetw; do want+="pkg-repo-probe: $p: forge-c green"$'\n'; done
for p in debian13 ubuntu2604 ubuntu2604/sqv; do want+="pkg-repo-probe: $p: forge-d green"$'\n'; done
want="$(printf '%s' "$want" | LC_ALL=C sort)"
cases=$((cases + 1))
if [ "$(verdicts "$log")" = "$want" ]; then
    echo "ok   ...(a) and (b) on all six passes, (c) on the rpm slugs, (d) on the apt slugs, Ubuntu under each verifier"
else
    echo "FAIL the forge verdicts are not the 18 expected"; diff <(echo "$want") <(verdicts "$log") | sed 's/^/  | /'; fail=1
fi
cases=$((cases + 1))
if [ "$(grep -c '^probe\[[a-z0-9/]*\]: forge-[abcd]: refused: ' "$log")" = 18 ]; then
    echo "ok   ...each refusal quoted from the client's own output"
else echo "FAIL not 18 quoted refusals"; grep 'refused' "$log" | sed 's/^/  | /'; fail=1; fi
cases=$((cases + 1))
if [ "$(sha_tree "$trees/tree-good")" = "$before" ]; then echo "ok   ...and the tree itself is unchanged"
else echo "FAIL P4 changed the tree it was given"; fail=1; fi

PROBE_FORGE_NOOP=1 probe_run good --steps forge --slugs "debian13 fedora44"
expect "RED the same steps with no forgery made" 1 "$rc" "forgery installed"
want="$(printf 'pkg-repo-probe: %s: %s red\n' debian13 forge-a debian13 forge-b debian13 forge-d \
    fedora44 forge-a fedora44 forge-b fedora44 forge-c | LC_ALL=C sort)"
cases=$((cases + 1))
if [ "$(verdicts "$log")" = "$want" ] && [ "$(grep -c '::error::forge-[abcd]: forgery installed' "$log")" = 6 ]; then
    echo "ok   ...every step red, each because it installed"
else echo "FAIL not every NOOP step is red"; diff <(echo "$want") <(verdicts "$log") | sed 's/^/  | /'; fail=1; fi

probe_run nopkgcheck --steps forge-c --slugs opensusetw
expect "RED (c) on opensusetw from a release package without pkg_gpgcheck=1" 1 "$rc" \
    "probe[opensusetw]: ::error::forge-c: forgery installed"

PROBE_FORGE_CLAIM=forge-d probe_run good --steps forge-a --slugs debian13
expect "RED a forgery refused in other words than its own (forge-a judged as forge-d)" 1 "$rc" \
    "probe[debian13]: ::error::forge-a: refused for the wrong reason: install/debian13.txt failed (rc 100)"

probe_run good --steps "forge p1p2" --slugs debian13
expect "a step after the forgeries is judged on the tree itself" 0 "$rc"
want="$(printf 'pkg-repo-probe: debian13: %s green\n' forge-a forge-b forge-d p1p2 | LC_ALL=C sort)"
cases=$((cases + 1))
if [ "$(grep -E '^pkg-repo-probe: debian13: (forge-[abcd]|p1p2) ' "$log" | LC_ALL=C sort)" = "$want" ]; then
    echo "ok   ...the three forgeries and then P1+P2, all green"
else echo "FAIL not every step green"; grep '^pkg-repo-probe:' "$log" | sed 's/^/  | /'; fail=1; fi

PROBE_FORGE_JOBS=0 probe_run good --steps forge-a --slugs debian13
expect "PROBE_FORGE_JOBS that is not a positive integer is rc 2" 2 "$rc" "PROBE_FORGE_JOBS='0' is not a positive integer"

rc=0; "$probe" --tree "$trees/tree-good" --install-dir "$inst" --keyset package-signing --steps forge >"$log" 2>&1 || rc=$?
expect "forgeries for a tree under another key than the probe key are rc 2" 2 "$rc" "forgeries are signed with the probe key"

# --- 8. /swap -----------------------------------------------------------------
# The server functions, sourced: serve tree A, swap to B, and a swap to a tree
# the server does not hold is refused and leaves B served.
mkdir -p "$work/swap-a" "$work/swap-b"
echo "tree A" >"$work/swap-a/KEYS"; echo "tree B" >"$work/swap-b/KEYS"
(
    # shellcheck source-path=SCRIPTDIR source=pkg-repo-probe.sh
    . "$probe"
    trap probe_down EXIT
    fetch() { docker run --rm --name "$PROBE_TAG-fetch" --network "$PROBE_NET" -v "$PROBE_WORK/tls/ca.pem:/ca.pem:ro" \
        "$PROBE_SERVER_IMAGE" curl -fsS --cacert /ca.pem https://librescrs.github.io/packages/KEYS; }
    probe_up "$work/swap-a" || exit 2
    a="$(fetch)"
    probe_serve "$work/swap-b" || exit 3
    b="$(fetch)"
    r=0; probe_swap g99 || r=$?
    c="$(fetch)"
    echo "A=$a B=$b refused=$r C=$c"
) >"$log" 2>&1
rc=$?
cases=$((cases + 1))
if [ "$rc" = 0 ] && grep -q '^A=tree A B=tree B refused=1 C=tree B$' "$log"; then
    echo "ok   /swap replaces the served tree, and refuses one it does not hold"
    red=$((red + 1))
else echo "FAIL /swap (rc=$rc)"; tail -n 20 "$log" | sed 's/^/  | /'; fail=1; fi

# --- cannot judge ---------------------------------------------------------------
PROBE_PASS_TIMEOUT=5 probe_run good --slugs debian13
expect "a pass over its deadline is rc 2, and names the pass" 2 "$rc" "cannot judge (timeout in debian13/p1p2 after 5s)"
probe_run good --steps "p1p2 nosuchstep"
expect "an unknown step is rc 2" 2 "$rc" "unknown step"
probe_run good --slugs "debian13 leap160"
expect "a slug with no first-contact file is rc 2" 2 "$rc" "leap160"

left="$(docker ps -aq --filter 'name=^probe-' | wc -l) $(docker network ls -q --filter 'name=^probe-' | wc -l)"
cases=$((cases + 1))
if [ "$left" = "0 0" ]; then echo "ok   no probe container or network is left"
else echo "FAIL left behind (containers, networks): $left"; fail=1; fi

echo "selftest: $cases cases, $red red-proved"
[ "$fail" = 0 ]
