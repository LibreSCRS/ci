#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-repo-probe.sh -- the publisher's probe: install from an assembled, signed
# package tree in clean distribution containers, exactly as a user would.
#
# Usage: pkg-repo-probe.sh --tree <t> --install-dir <dir> --keyset <rehearsal|package-signing>
#                          [--prev <tree>] [--slugs "<slug> ..."] [--steps "<step> ..."]
#
#   --tree         the tree to publish (pkg-repo.py assemble + sign-index)
#   --install-dir  the packages repository's install/: the first-contact
#                  commands, one file per distribution (debian13.txt,
#                  ubuntu2604.txt, fedora.txt for both Fedoras, opensusetw.txt;
#                  arch.txt, not run, has its URLs judged as the others)
#   --keyset       the key set the tree is signed with; its certificate must be
#                  the tree's KEY.asc
#   --prev         the previous generation, as fetch-prev mirrors it, the stable
#                  aliases and KEYS included (upgrade and key); absent, or
#                  holding EMPTY (fetch-prev found nothing published), those
#                  steps are skipped with the reason, rc 0
#   --slugs        default: debian13 ubuntu2604 fedora43 fedora44 opensusetw
#   --steps        default: p1p2
#
# Steps:
#   p1p2  P1, first contact: install/<file>.txt byte for byte, run as
#         `bash -euxo pipefail /tmp/i.sh </dev/null`; P2, installation: what
#         librecelik must bring with it, and librekde with its five parts
#         (pkg-repo-probe-inside.sh). Ubuntu runs twice: apt verifying with
#         gpgv, and with the Sequoia verifier installed (PROBE_APT_VERIFIER=sqv).
#   forge P4, forgeries: forge-a forge-b forge-c forge-d (each can also be
#         named alone). Each serves a copy of the tree with one defect, and
#         P1 there must fail with the client's own words for that defect:
#           forge-a  one byte of librecelik in the pool         every slug
#           forge-b  every index signed by a throwaway key B    every slug
#           forge-c  librecelik unsigned, the index re-made and
#                    correctly signed                           rpm slugs
#           forge-d  InRelease past its Valid-Until, correctly
#                    signed                                     apt slugs
#         The probe job holds no index key, so whatever is signed again is
#         signed with the probe key (keys/rehearsal.*): forge runs only on a
#         tree under that key, whose keyring packages make it the one the
#         clients trust. The copies are hard links with each changed file
#         replaced, never written through; the tree's digest is checked
#         unchanged at the end. Up to PROBE_FORGE_JOBS (default 3) passes of
#         one forgery run at a time; after them the tree itself is served
#         again, so a later step never judges a forgery. Key B's fingerprint
#         goes to the clients (PROBE_FORGE_KEY): apt and zypper must name it.
#         PROBE_FORGE_NOOP=1 leaves the defect out (and is red: "forgery
#         installed"); PROBE_FORGE_CLAIM=<forge-x> (self-test only) has the
#         clients expect another forgery's words (red: "refused for the wrong
#         reason").
#   upgrade P3: each client runs P1 while the server serves --prev; then the
#         tree is served (POST /swap), the client refreshes the LibreSCRS
#         repository alone and upgrades. Every package P1 installed, read from
#         the package database, must then be at the newest version the tree's
#         index names for the slug; a tree with nothing newer (a re-sign) is
#         green and says so. The client must also hold the tree's own signed
#         index (InRelease, repomd.xml) byte for byte: apt and dnf exit 0
#         while they keep an older index they could not replace. A failure in
#         a repository that is not LibreSCRS cannot be judged.
#   key   P5: the same, with the certificate the client trusted from the
#         previous generation's keyring package and no new trust action:
#         after the upgrade librecelik is installed once more from the tree,
#         so its signature is checked by the key the client kept. And every
#         signature of --prev -- InRelease, Release.gpg, repomd.xml.asc (made
#         by the key set's S_IDX_FPR, the first VALIDSIG field) and every rpm
#         (pkg-sign.sh --verify-only) -- must verify against the tree's KEY.asc.
#   Both: a Fedora the tree has no rpm/<slug>/ for (a Fedora newer than the
#         repository) must keep working -- dnf makecache and dnf upgrade rc 0,
#         nothing removed, under a dnf.conf that says skip_if_unavailable=False
#         (Fedora's own defaults skip, and would hide what the release package
#         says); any other slug missing from the tree is a finding,
#         and a slug --prev lacks is skipped with the reason. The passes run
#         PROBE_FORGE_JOBS at a time: all of a batch install from --prev,
#         then the tree is served to all of them.
#
# Before any container runs, every place a first-contact file names must be
# under https://librescrs.github.io/packages/ -- a scheme://URL, a wget or curl
# argument that is no option, a host.tld/... or IPv4 word; any other is a finding.
#
# Every client pass has a deadline (PROBE_PASS_TIMEOUT, default 1200 s) and the
# server one to come up (PROBE_SERVER_TIMEOUT, default 300 s); past either the
# probe cannot judge, and names the pass.
#
# The network: a Docker network of this run's own, a throwaway CA made here
# with openssl, and a server container (the fedora43 image) with the network
# alias librescrs.github.io that serves the tree over HTTPS on 443 at
# https://librescrs.github.io/packages/. The clients trust the CA and so run
# the published text and the installed keyring packages without changing a
# URL. The server's POST /swap (reachable only on the probe network) serves
# another tree the probe has handed it, atomically: probe_serve <dir>.
# Everything this run starts is named after it and removed on exit.
#
# Sourcing this file defines the server functions (probe_up, probe_serve,
# probe_swap, probe_down) and runs nothing.
#
# Environment for upgrade and key: PROBE_FORGE_JOBS, the passes at a time.
#
# Environment: PKG_DOCKER as pkg-gate.sh; PROBE_KEEP_IMAGE_DEFAULTS and
# PROBE_NO_ZYPPER_WRAPPER are handed to the clients (pkg-repo-probe-inside.sh);
# PROBE_OLDSIGS_TIMEOUT (default 1200 s) bounds key's check of the old
# signatures.
#
# Exit codes: 0 every pass green, 1 a finding, 2 cannot judge.
set -uo pipefail

PROBE_HERE="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)" || exit 2
PROBE_BASE="https://librescrs.github.io/packages/"
PROBE_HOST="librescrs.github.io"
DOCKER="${PKG_DOCKER:-docker}"
PROBE_TAG="probe-$$-$RANDOM"
PROBE_NET="$PROBE_TAG"
PROBE_WORK=""
PROBE_SERVER_IMAGE=""
PROBE_GEN=0
PROBE_STAGED=""

probe_die2() { echo "pkg-repo-probe: $* -- cannot judge" >&2; exit 2; }

# The server: ThreadingHTTPServer over TLS, GET/HEAD under /packages/ from the
# current tree, POST /swap with the name of a tree under /www.
probe_server_py() {
    cat <<'EOF'
import http.server, os, re, ssl, sys

WWW = sys.argv[1]
state = {"root": os.path.join(WWW, sys.argv[2])}
PREFIX = "/packages/"


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # as Pages: apt keeps the connection

    def translate_path(self, path):
        path = path.split("?", 1)[0].split("#", 1)[0]
        if not path.startswith(PREFIX):
            return "/nonexistent"
        self.directory = state["root"]
        return super().translate_path("/" + path[len(PREFIX):])

    def list_directory(self, path):  # Pages lists no directory
        self.send_error(404)
        return None

    def do_POST(self):
        if self.path != "/swap":
            self.send_error(404)
            return
        name = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode().strip()
        d = os.path.join(WWW, name)
        if not re.fullmatch(r"g[0-9]+", name) or not os.path.isdir(d):
            self.send_error(409, f"no tree {name!r}")
            return
        state["root"] = d
        body = f"serving {name}\n".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/tls/server.pem", "/tls/server.key")
httpd = http.server.ThreadingHTTPServer(("", 443), Handler)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
httpd.serve_forever()
EOF
}

# probe_ca -- a throwaway CA and a certificate for librescrs.github.io
probe_ca() {
    local t="$PROBE_WORK/tls"
    mkdir -p "$t" || return 2
    {
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$t/ca.key" -out "$t/ca.pem" \
            -days 2 -subj "/CN=LibreSCRS probe CA (throwaway)" \
            -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        && openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$t/server.key" \
            -out "$t/server.csr" -subj "/CN=$PROBE_HOST" \
        && printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$PROBE_HOST" \
            >"$t/ext" \
        && openssl x509 -req -in "$t/server.csr" -CA "$t/ca.pem" -CAkey "$t/ca.key" -set_serial "0x$(openssl rand -hex 8)" \
            -days 2 -extfile "$t/ext" -out "$t/server.pem"
    } >"$t/openssl.log" 2>&1 || { cat "$t/openssl.log" >&2; return 2; }
    chmod 0644 "$t/ca.pem"
    rm -f "$t/ca.key"
}

# probe_srv_curl ARGS... -- curl in the server container, to itself by name
probe_srv_curl() {
    "$DOCKER" exec "$PROBE_TAG-server" curl -sS --cacert /tls/ca.pem --resolve "$PROBE_HOST:443:127.0.0.1" "$@"
}

# probe_stage DIR -- copy DIR next to the served trees, as $PROBE_STAGED (set
# here, never read through $(...): the generation count lives in this shell).
# The copy is hard links where it can be: a tree is never changed in place.
probe_stage() {
    local name
    PROBE_GEN=$((PROBE_GEN + 1))
    name="g$PROBE_GEN"
    [ -d "$1" ] || { echo "pkg-repo-probe: no tree at $1" >&2; return 2; }
    [ ! -e "$PROBE_WORK/www/$name" ] || { echo "pkg-repo-probe: $name is already staged" >&2; return 2; }
    command cp -al "$1" "$PROBE_WORK/www/$name" 2>/dev/null \
        || { rm -rf "${PROBE_WORK:?}/www/$name"; command cp -a "$1" "$PROBE_WORK/www/$name"; } || return 2
    PROBE_STAGED="$name"
}

# probe_swap NAME -- serve the staged tree NAME; 1 when the server refuses
probe_swap() {
    local code
    code="$(probe_srv_curl --max-time 30 -o /dev/null -w '%{http_code}' -X POST --data-binary "$1" "https://$PROBE_HOST/swap")" \
        || return 2
    case "$code" in
        200) return 0 ;;
        409) echo "pkg-repo-probe: the server holds no tree '$1'" >&2; return 1 ;;
        *)   echo "pkg-repo-probe: /swap answered $code" >&2; return 2 ;;
    esac
}

# probe_serve DIR -- serve DIR from now on
probe_serve() {
    probe_stage "$1" || return 2
    probe_swap "$PROBE_STAGED"
}

# probe_up TREE -- the network, the CA and the server serving TREE
probe_up() {
    command -v "$DOCKER" >/dev/null 2>&1 || { echo "pkg-repo-probe: $DOCKER is not on PATH" >&2; return 2; }
    command -v openssl >/dev/null 2>&1 || { echo "pkg-repo-probe: openssl is not on PATH" >&2; return 2; }
    PROBE_SERVER_IMAGE="$("$PROBE_HERE/pkg-images" get fedora43)" || return 2
    PROBE_WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/pr.XXXXXX")" || return 2
    mkdir -p "$PROBE_WORK/www" || return 2
    probe_ca || return 2
    probe_server_py >"$PROBE_WORK/server.py"
    probe_stage "$1" || return 2
    "$DOCKER" network create "$PROBE_NET" >/dev/null || return 2
    # shellcheck disable=SC2016  # the script runs in the container; its $ are not ours
    "$DOCKER" run -d --name "$PROBE_TAG-server" --network "$PROBE_NET" --network-alias "$PROBE_HOST" \
        -v "$PROBE_WORK/www:/www:ro" -v "$PROBE_WORK/tls:/tls:ro" -v "$PROBE_WORK/server.py:/server.py:ro" \
        "$PROBE_SERVER_IMAGE" bash -c 'dnf -y -q install python3 >/dev/null && exec python3 -I /server.py /www "$0"' \
        "$PROBE_STAGED" >/dev/null || return 2
    # up once it answers at all (tree A of a test need not hold KEY.asc),
    # within PROBE_SERVER_TIMEOUT seconds
    local start=$SECONDS limit="${PROBE_SERVER_TIMEOUT:-300}"
    while [ $((SECONDS - start)) -lt "$limit" ]; do
        [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$PROBE_TAG-server" 2>/dev/null)" = true ] || break
        if [ "$(probe_srv_curl --max-time 5 -o /dev/null -w '%{http_code}' "$PROBE_BASE" 2>/dev/null)" != 000 ]; then
            echo "pkg-repo-probe: serving $1 at $PROBE_BASE (after $((SECONDS - start))s)"
            return 0
        fi
        sleep 1
    done
    echo "pkg-repo-probe: the server did not come up within ${limit}s" >&2
    "$DOCKER" logs "$PROBE_TAG-server" 2>&1 | tail -n 20 >&2
    return 2
}

probe_down() {
    if [ -n "${PROBE_KEYB:-}" ]; then
        GNUPGHOME="$PROBE_KEYB/gnupg" gpgconf --kill all >/dev/null 2>&1
        GNUPGHOME="$PROBE_KEYB/gnupg" gpgconf --remove-socketdir >/dev/null 2>&1
    fi
    "$DOCKER" ps -aq --filter "name=^$PROBE_TAG-" | xargs -r "$DOCKER" rm -f >/dev/null 2>&1
    "$DOCKER" network rm "$PROBE_NET" >/dev/null 2>&1
    [ -z "$PROBE_WORK" ] || rm -rf "$PROBE_WORK"
}

# probe_urls FILE -- 1 when FILE names a place outside the published base:
# a scheme://URL not under it, a wget or curl argument that is no option and
# not under it, or a word shaped like host.tld/... or an IPv4 address (a
# host without a scheme, which wget and curl fetch all the same)
probe_urls() {
    local line w cmd iscmd bad=0 f
    f="$(basename -- "$1")"
    while IFS= read -r line || [ -n "$line" ]; do
        local -a words=()
        read -ra words <<<"$line"
        cmd=""
        for w in "${words[@]}"; do
            iscmd=0
            if [ -z "$cmd" ]; then
                case "$w" in sudo|env|*=*) ;; *) cmd="${w##*/}"; iscmd=1 ;; esac
            fi
            case "$w" in "$PROBE_BASE"*) continue ;; esac
            if [[ "$w" == *://* ]] \
                || { [ "$iscmd" = 0 ] && [[ "$cmd" == wget || "$cmd" == curl ]] && [[ "$w" != -* ]]; } \
                || [[ "$w" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}(:[0-9]+)?/ ]] \
                || [[ "$w" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?(/|$) ]]; then
                echo "::error::$f: $w is not under $PROBE_BASE"
                bad=1
            fi
        done
    done <"$1"
    return "$bad"
}

# --- P4, forgeries -------------------------------------------------------------
# Each forgery is a copy of the tree (hard links) in which only the files the
# forgery changes are replaced by new ones, so the tree itself is never written.
# PROBE_FORGE_NOOP=1 makes every copy without its defect (the indexes are still
# rebuilt and signed as for the forgery): the probe must then be red.

probe_codename() { case "$1" in debian13) echo trixie ;; ubuntu2604) echo resolute ;; *) return 2 ;; esac; }

# probe_forge_applies STEP MANAGER -- whether STEP concerns MANAGER's clients:
# an unsigned rpm only the rpm clients, an expired InRelease only apt
probe_forge_applies() {
    case "$1:$2" in
        p1p2:*|upgrade:*|key:*|forge-a:*|forge-b:*|forge-c:dnf|forge-c:zypper|forge-d:apt) return 0 ;;
        *) return 1 ;;
    esac
}

# probe_own FILE -- FILE as a file of its own (no longer a link into the tree)
probe_own() {
    command cp -pf -- "$1" "$1.own" && mv -f -- "$1.own" "$1"
}

# probe_librecelik SLUG MANAGER DIR -- the librecelik packages of SLUG in DIR
probe_librecelik() {
    local c
    case "$2" in
        apt) c="$(probe_codename "$1")" || return 2; compgen -G "$3/deb/pool/$c/librecelik_*.deb" ;;
        *)   compgen -G "$3/rpm/$1/librecelik-[0-9]*.rpm" ;;
    esac
}

# probe_flip FILE -- the byte in the middle of FILE inverted, in a file of its own
probe_flip() {
    local before
    before="$(sha256sum <"$1")"
    probe_own "$1" || return 2
    python3 -I -c '
import os, sys
with open(sys.argv[1], "r+b") as f:
    n = os.fstat(f.fileno()).st_size
    f.seek(n // 2); b = f.read(1); f.seek(n // 2); f.write(bytes([b[0] ^ 0xFF]))' "$1" || return 2
    [ "$(sha256sum <"$1")" != "$before" ] || { echo "pkg-repo-probe: $1 did not change" >&2; return 2; }
}

# probe_sign_b TREE -- every index of TREE signed by a throwaway key B alone,
# made in a GNUPGHOME of its own ($PROBE_KEYB)
probe_sign_b() {
    local fpr f d
    PROBE_KEYB="$PROBE_WORK/keyb"
    mkdir -p "$PROBE_KEYB/gnupg" "$PROBE_KEYB/sq" && chmod 700 "$PROBE_KEYB/gnupg" || return 2
    local -x GNUPGHOME="$PROBE_KEYB/gnupg" SEQUOIA_HOME="$PROBE_KEYB/sq"
    gpg --batch --no-tty --pinentry-mode loopback --passphrase '' \
        --quick-gen-key 'not LibreSCRS: probe forgery key B <forgery@invalid>' ed25519 sign never >/dev/null 2>&1 \
        || { echo "pkg-repo-probe: cannot make key B" >&2; return 2; }
    fpr="$(gpg --batch --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }')"
    [[ "$fpr" =~ ^[0-9A-F]{40}$ ]] || { echo "pkg-repo-probe: key B's home holds other keys than B" >&2; return 2; }
    local g=(gpg --batch --yes --no-tty --pinentry-mode loopback --passphrase '' --local-user "$fpr!" --digest-algo SHA512)
    for f in "$1"/deb/dists/*/Release; do
        [ -f "$f" ] || continue
        d="$(dirname "$f")"
        rm -f "$d/InRelease" "$d/Release.gpg"
        { "${g[@]}" --clearsign --output "$d/InRelease" "$f" && "${g[@]}" --detach-sign --output "$d/Release.gpg" "$f"; } \
            2>/dev/null || return 2
    done
    for f in "$1"/rpm/*/repodata/repomd.xml; do
        [ -f "$f" ] || continue
        rm -f "$f.asc"
        "${g[@]}" --detach-sign --armor --output "$f.asc" "$f" 2>/dev/null || return 2
    done
    PROBE_KEYB_FPR="$fpr"
    echo "pkg-repo-probe: forge-b: the indexes are signed by key B $fpr"
}

# probe_unsign SLUG FILE... -- the signature removed from each FILE by the rpm
# of SLUG's own distribution, and checked gone
probe_unsign() {
    local s="$1" st f; shift
    st="$(mktemp -d "$PROBE_WORK/unsign.XXXXXX")" || return 2
    for f in "$@"; do command cp -f -- "$f" "$st/" || return 2; done
    # shellcheck disable=SC2016  # the script runs in the container; its $ are not ours
    "$DOCKER" run --rm --name "$PROBE_TAG-unsign-$s" -v "$st:/p" -e "OWN=$(id -u):$(id -g)" \
        -e "MANAGER=${PROBE_MANAGER[$s]}" "${PROBE_IMAGE[$s]}" bash -c '
        set -eu
        trap "chown -R \"$OWN\" /p" EXIT
        [ "$MANAGER" != dnf ] || dnf -y -q install rpm-sign >/dev/null
        for f in /p/*.rpm; do
            rpmsign --delsign "$f" >/dev/null
            if rpmkeys -Kv "$f" | grep -qi signature; then echo "$f is still signed" >&2; exit 1; fi
        done' >"$st.log" 2>&1 &
    wait "$!" || { cat "$st.log" >&2; return 2; }
    for f in "$@"; do
        rm -f -- "$f" && command cp -f -- "$st/$(basename -- "$f")" "$f" || return 2
    done
    rm -rf "$st" "$st.log"
}

# probe_expire TREE CODENAME -- Release dated forty days back and valid until
# ten days ago, in a file of its own
probe_expire() {
    local r="$1/deb/dists/$2/Release"
    [ -f "$r" ] || { echo "pkg-repo-probe: no $r" >&2; return 2; }
    probe_own "$r" || return 2
    python3 -I -c '
import email.utils, re, sys, time
p, now = sys.argv[1], time.time()
t = open(p).read()
rfc = lambda s: email.utils.formatdate(s, usegmt=True)
t, n1 = re.subn(r"(?m)^Date: .*$", "Date: " + rfc(now - 40 * 86400), t)
t, n2 = re.subn(r"(?m)^Valid-Until: .*$", "Valid-Until: " + rfc(now - 10 * 86400), t)
if (n1, n2) != (1, 1):
    sys.exit(f"{p}: Date/Valid-Until found {n1}/{n2} times")
open(p, "w").write(t)' "$r" || return 2
}

# probe_sign_index TREE -- the indexes of TREE signed with the probe key
probe_sign_index() {
    python3 -I "$PROBE_HERE/pkg-repo.py" sign-index --tree "$1" --keyset rehearsal >"$PROBE_WORK/sign-index.log" 2>&1 \
        || { cat "$PROBE_WORK/sign-index.log" >&2; return 2; }
}

# probe_forge STEP TREE SLUGS -- the forgery STEP of TREE for SLUGS, made in
# $PROBE_WORK/STEP: the copy, the defect, then what must be signed again
probe_forge() {
    local step="$1" tree="$2" slugs="$3" out="$PROBE_WORK/$1" s f noop="${PROBE_FORGE_NOOP:-}"
    local -a files
    [ ! -e "$out" ] || { echo "pkg-repo-probe: $out exists" >&2; return 2; }
    command cp -al "$tree" "$out" 2>/dev/null || { rm -rf "$out"; command cp -a "$tree" "$out"; } || return 2
    [ "$noop" != 1 ] || echo "pkg-repo-probe: $step without its defect (PROBE_FORGE_NOOP=1)"
    case "$step" in
        forge-a)   # one byte of the package the install fetches
            for s in $slugs; do
                mapfile -t files < <(probe_librecelik "$s" "${PROBE_MANAGER[$s]}" "$out")
                [ "${#files[@]}" -gt 0 ] || { echo "pkg-repo-probe: no librecelik for $s in the tree" >&2; return 2; }
                [ "$noop" = 1 ] || for f in "${files[@]}"; do probe_flip "$f" || return 2; done
            done ;;
        forge-b)   # every index signed by a key the clients do not know
            [ "$noop" = 1 ] || probe_sign_b "$out" || return 2 ;;
        forge-c)   # librecelik unsigned, named by an index that is correctly signed
            for s in $slugs; do
                probe_forge_applies forge-c "${PROBE_MANAGER[$s]}" || continue
                mapfile -t files < <(probe_librecelik "$s" "${PROBE_MANAGER[$s]}" "$out")
                [ "${#files[@]}" -gt 0 ] || { echo "pkg-repo-probe: no librecelik for $s in the tree" >&2; return 2; }
                [ "$noop" = 1 ] || probe_unsign "$s" "${files[@]}" || return 2
                rm -rf "${out:?}/rpm/$s/repodata" || return 2
                "$PROBE_HERE/pkg-repo-index.sh" rpm "$out" "$s" >"$PROBE_WORK/index.log" 2>&1 \
                    || { cat "$PROBE_WORK/index.log" >&2; return 2; }
                command cp -f "$tree/rpm/$s/repodata/repomd.xml.key" "$out/rpm/$s/repodata/" || return 2
            done
            probe_sign_index "$out" || return 2 ;;
        forge-d)   # an InRelease past its Valid-Until, correctly signed
            for s in $slugs; do
                probe_forge_applies forge-d "${PROBE_MANAGER[$s]}" || continue
                [ "$noop" = 1 ] || probe_expire "$out" "$(probe_codename "$s")" || return 2
            done
            probe_sign_index "$out" || return 2 ;;
        *) return 2 ;;
    esac
}

# probe_sum TREE -- one digest over every file of TREE and its path
probe_sum() {
    (cd -- "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) | sha256sum
}

# --- P3 and P5, the previous generation ----------------------------------------

# probe_helper_py -- what the probe reads of a tree, with pkg-repo.py's own
# readers and verification (loaded from next to this file):
#   versions TREE SLUG MANAGER NAME...  "<name>=<version>" for every version
#       of each NAME the slug's index names (rpm: [E:]V-R as rpm -q prints it)
#   oldsigs PREV TREE KEYSET WORK  every index signature of PREV verified
#       against TREE's KEY.asc, made by the key set's S_IDX_FPR, with the hash
#       chains they sign; then every rpm of PREV through pkg-sign.sh
#       --verify-only, which judges against keys/KEYSET.asc -- the tree's
#       KEY.asc byte for byte, as the probe checked before anything ran
probe_helper_py() {
    cat <<'EOF'
import importlib.util, os, re, shutil, sys, tempfile
import xml.etree.ElementTree as ET

here, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
spec = importlib.util.spec_from_file_location("pkg_repo", os.path.join(here, "pkg-repo.py"))
pr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pr)


def versions(tree, slug, manager, names):
    found = set()
    if manager == "apt":
        codename = pr.DEB_SLUGS[slug][0]
        with open(os.path.join(tree, "deb", "dists", codename, "main", "binary-amd64", "Packages")) as f:
            text = f.read()
        for stanza in re.split(r"\n\s*\n", text.strip()):
            fields = dict(l.split(": ", 1) for l in stanza.splitlines() if ": " in l and not l.startswith(" "))
            if fields.get("Package") in names:
                found.add(f"{fields['Package']}={fields['Version']}")
    else:
        base = os.path.join(tree, "rpm", slug)
        root = ET.parse(os.path.join(base, "repodata", "repomd.xml")).getroot()
        primary = [d.find(f"{pr.RPM_MD}location").get("href") for d in root.findall(f"{pr.RPM_MD}data")
                   if d.get("type") == "primary"]
        if len(primary) != 1:
            raise pr.Cannot(f"{base}/repodata/repomd.xml names {len(primary)} primary")
        for p in ET.fromstring(pr.read_compressed(os.path.join(base, primary[0]))).findall(f"{pr.RPM_COMMON}package"):
            name, v = p.findtext(f"{pr.RPM_COMMON}name"), p.find(f"{pr.RPM_COMMON}version")
            if name in names:
                epoch = v.get("epoch") or "0"
                found.add(f"{name}={'' if epoch == '0' else epoch + ':'}{v.get('ver')}-{v.get('rel')}")
    print(" ".join(sorted(found)))
    return 0


def oldsigs(prev, tree, keyset, work):
    cert = os.path.join(tree, "KEY.asc")
    idx = pr.keyset_env(keyset)[1]
    pr.keyset_env = lambda _keyset: (cert, idx)  # the tree's KEY.asc, the key set's index subkey
    home = tempfile.mkdtemp(dir=work, prefix="lg.")
    stage = tempfile.mkdtemp(dir=work, prefix="oldrpm.")
    try:
        sg = pr.Signer(keyset, home)
        m = pr.Tree(prev)
        sigs = 0
        for c in pr.CODENAMES:
            if os.path.isfile(os.path.join(prev, "deb", "dists", c, "InRelease")):
                pr.fetch_deb(m, sg, c, home)  # InRelease and Release.gpg; no Valid-Until: it is old
                sigs += 2
        rpms = 0
        for slug in pr.RPM_SLUGS:
            d = os.path.join(prev, "rpm", slug)
            if not os.path.isfile(os.path.join(d, "repodata", "repomd.xml")):
                continue
            with open(os.path.join(d, "repodata", "repomd.xml.key"), "rb") as f:
                own = f.read()  # the generation's own key file; the signature is judged by the tree's
            named = pr.fetch_rpm(m, sg, slug, own, required=True)
            sigs += 1
            for path in sorted(set(named) | {os.path.join(d, n) for n in os.listdir(d) if n.endswith(".rpm")}):
                link = os.path.join(stage, f"{os.path.basename(path)[:-4]}.{slug}.rpm")
                if not os.path.lexists(link):
                    os.symlink(os.path.realpath(path), link)
                    rpms += 1
        if sigs == 0:
            raise pr.Cannot(f"{prev} holds no signed index")
        rc = pr.verify_rpms(stage, keyset, "P5: the previous generation's rpms")
        if rc == 0:
            print(f"pkg-repo-probe: key: {sigs} index signatures and {rpms} rpms of the previous generation verified")
            print("pkg-repo-probe: key: the previous generation's signatures verify against the tree's KEY.asc")
        return rc
    finally:
        shutil.rmtree(stage, ignore_errors=True)
        pr.drop_home(home)


try:
    sys.exit(versions(args[0], args[1], args[2], set(args[3:])) if cmd == "versions" else oldsigs(*args))
except pr.Finding as e:
    print(f"::error::P5: {e}")
    sys.exit(1)
except (pr.Cannot, OSError, ValueError, KeyError, ET.ParseError) as e:
    print(f"pkg-repo-probe: {cmd}: {e} -- cannot judge", file=sys.stderr)
    sys.exit(2)
EOF
}

# probe_where SLUG -- the place of SLUG in a tree
probe_where() {
    case "${PROBE_MANAGER[$1]}" in
        apt) echo "deb/dists/$(probe_codename "$1")/" ;;
        *)   echo "rpm/$1/" ;;
    esac
}

# probe_has TREE SLUG -- TREE holds SLUG's signed index
probe_has() {
    case "${PROBE_MANAGER[$2]}" in
        apt) [ -f "$1/deb/dists/$(probe_codename "$2")/InRelease" ] ;;
        *)   [ -f "$1/rpm/$2/repodata/repomd.xml" ] ;;
    esac
}

# probe_label PASS -- slug[/sqv] of a pass slug:verifier
probe_label() { if [ "${1#*:}" = sqv ]; then echo "${1%%:*}/sqv"; else echo "${1%%:*}"; fi; }

# probe_generation STEP JOBS TREE PREV PASS... -- P3 (upgrade) or P5 (key)
# over PASSES, JOBS at a time; 0 green, 1 red, 2 cannot judge. PROBE_LOST=1
# when a swap failed: the server then serves an unknown tree, and no later
# step may run.
probe_generation() {
    local step="$1" jobs="$2" tree="$3" prev="$4" pass s rc verdict=0 i n go d vers gone idx
    shift 4
    local -a ok=() batch=()
    local -A tv=() tg=() ti=()
    local out="$PROBE_WORK/out/$step"
    mkdir -p "$out" || return 2
    if [ "$step" = key ]; then
        rc=0
        # TERM first: it reaches pkg-sign.sh, whose trap removes its containers
        local limit="${PROBE_OLDSIGS_TIMEOUT:-1200}"
        timeout -k 60 "$limit" python3 -I -B -c "$(probe_helper_py)" "$PROBE_HERE" oldsigs "$prev" "$tree" "$PROBE_KEYSET" \
            "$PROBE_WORK" || rc=$?
        case "$rc" in
            0) echo "pkg-repo-probe: key: old signatures green" ;;
            1) echo "pkg-repo-probe: key: old signatures red"; verdict=1 ;;
            124|137) echo "pkg-repo-probe: key: old signatures cannot judge (timeout after ${limit}s)"; verdict=2 ;;
            *) echo "pkg-repo-probe: key: old signatures cannot judge (rc $rc)"; verdict=2 ;;
        esac
    fi
    for pass in "$@"; do
        s="${pass%%:*}"
        if ! probe_has "$prev" "$s"; then
            echo "pkg-repo-probe: $(probe_label "$pass"): $step skipped: the previous generation has no $(probe_where "$s")"
            continue
        fi
        gone=""
        if ! probe_has "$tree" "$s"; then
            case "$s" in
                fedora*) gone=1 ;;
                *) echo "::error::$step: the tree has no $(probe_where "$s") for $s"
                   echo "pkg-repo-probe: $(probe_label "$pass"): $step red"
                   [ "$verdict" = 2 ] || verdict=1
                   continue ;;
            esac
        fi
        vers=""
        if [ -z "$gone" ]; then
            local -a names=(librecelik librescrs-agent librescrs-pinentry-kde librescrs-card-plugins)
            case "${PROBE_MANAGER[$s]}" in
                apt) names+=(liblibrescrs5 librescrs-archive-keyring) ;;
                *)   names+=(librescrs-middleware librescrs-release) ;;
            esac
            vers="$(python3 -I -B -c "$(probe_helper_py)" "$PROBE_HERE" versions "$tree" "$s" "${PROBE_MANAGER[$s]}" "${names[@]}")" \
                || { echo "pkg-repo-probe: $step: cannot read the versions of $s in the tree -- cannot judge"; return 2; }
        fi
        idx=""
        if [ -z "$gone" ]; then
            case "${PROBE_MANAGER[$s]}" in
                apt) idx="$(sha256sum <"$tree/deb/dists/$(probe_codename "$s")/InRelease")" ;;
                *)   idx="$(sha256sum <"$tree/rpm/$s/repodata/repomd.xml")" ;;
            esac || { echo "pkg-repo-probe: $step: cannot read the index of $s in the tree -- cannot judge"; return 2; }
            idx="${idx%% *}"
        fi
        tv[$pass]="$vers" tg[$pass]="$gone" ti[$pass]="$idx"
        ok+=("$pass")
    done
    for pass in "${ok[@]}"; do mkdir -p "$out/${pass/:/-}" || return 2; done
    for ((i = 0; i < ${#ok[@]}; i += jobs)); do
        batch=("${ok[@]:i:jobs}")
        if ! probe_swap "$PROBE_PREV_STAGED"; then
            echo "pkg-repo-probe: $step: the previous generation is not served -- cannot judge"
            PROBE_LOST=1
            return 2
        fi
        for pass in "${batch[@]}"; do
            d="$out/${pass/:/-}"
            ( rc=0
              probe_pass "$step" "${pass%%:*}" "${pass#*:}" -v "$d:/probe/sync" -e "PROBE_TREE_VERSIONS=${tv[$pass]}" \
                  -e "PROBE_TREE_GONE=${tg[$pass]}" -e "PROBE_TREE_INDEX=${ti[$pass]}" \
                  -e "PROBE_PASS_TIMEOUT=${PROBE_PASS_TIMEOUT:-1200}" >"$d.log" 2>&1 || rc=$?
              echo "$rc" >"$d.rc" ) &
        done
        # every pass of the batch has installed from the previous generation
        # (ready) or is done; each pass has its deadline, so this ends
        while :; do
            n=0
            for pass in "${batch[@]}"; do
                d="$out/${pass/:/-}"
                [ -e "$d/ready" ] || [ -e "$d.rc" ] || n=$((n + 1))
            done
            [ "$n" = 0 ] && break
            sleep 1
        done
        go=go
        probe_swap "$PROBE_TREE_STAGED" || go=abort
        for pass in "${batch[@]}"; do : >"$out/${pass/:/-}/$go"; done
        wait
        for pass in "${batch[@]}"; do
            d="$out/${pass/:/-}"
            cat "$d.log"
            rc="$(cat "$d.rc" 2>/dev/null)" || rc=2
            case "$rc" in 0|1) ;; *) rc=2 ;; esac
            [ "$rc" = 0 ] || [ "$verdict" = 2 ] || verdict="$rc"
        done
        if [ "$go" != go ]; then
            echo "pkg-repo-probe: $step: the tree is not served after the previous generation -- cannot judge"
            PROBE_LOST=1
            return 2
        fi
    done
    return "$verdict"
}

# probe_pass STEP SLUG VERIFIER [DOCKER-ARG...] -- one client pass: prints its
# verdict line and returns it (0 green, 1 red, 2 cannot judge)
probe_pass() {
    local step="$1" s="$2" verifier="$3" label rc cname start limit="${PROBE_PASS_TIMEOUT:-1200}"
    shift 3
    label="$s"; [ "$verifier" != sqv ] || label="$s/sqv"
    echo "-- $label: $step in ${PROBE_IMAGE[$s]}"
    # In the background and waited for, so a signal reaches the trap at once
    # instead of after the container finishes. A pass has a deadline; the
    # docker client is killed then (it would forward a TERM to the container
    # and keep waiting) and the container removed.
    cname="$PROBE_TAG-$s-$verifier-$step"
    start=$SECONDS
    timeout -s KILL "$limit" "$DOCKER" run --rm --name "$cname" --network "$PROBE_NET" \
        -v "$PROBE_WORK/tls/ca.pem:/probe/ca.pem:ro" -v "$PROBE_INST/${PROBE_FILE[$s]}:/probe/install.txt:ro" \
        -v "$PROBE_HERE/pkg-repo-probe-inside.sh:/probe/inside.sh:ro" \
        -e "SLUG=$s" -e "MANAGER=${PROBE_MANAGER[$s]}" -e "STEP=$step" -e "INSTALL=${PROBE_FILE[$s]}" \
        -e "PROBE_APT_VERIFIER=$verifier" -e "PROBE_KEEP_IMAGE_DEFAULTS=${PROBE_KEEP_IMAGE_DEFAULTS:-}" \
        -e "PROBE_NO_ZYPPER_WRAPPER=${PROBE_NO_ZYPPER_WRAPPER:-}" -e "PROBE_INDEX_FPR=$PROBE_IDX" \
        -e "PROBE_FORGE_KEY=$PROBE_KEYB_FPR" -e "PROBE_FORGE_CLAIM=${PROBE_FORGE_CLAIM:-}" \
        "$@" "${PROBE_IMAGE[$s]}" bash /probe/inside.sh &
    rc=0; wait "$!" || rc=$?
    if [ "$rc" -ge 124 ] && [ $((SECONDS - start)) -ge "$limit" ]; then
        "$DOCKER" rm -f "$cname" >/dev/null 2>&1
        echo "pkg-repo-probe: $label: $step cannot judge (timeout in $label/$step after ${limit}s)"
        return 2
    fi
    case "$rc" in
        0) echo "pkg-repo-probe: $label: $step green"; return 0 ;;
        1) echo "pkg-repo-probe: $label: $step red"; return 1 ;;
        *) echo "pkg-repo-probe: $label: $step cannot judge (rc $rc)"; return 2 ;;
    esac
}

declare -A PROBE_FILE=() PROBE_IMAGE=() PROBE_MANAGER=()
PROBE_INST="" PROBE_IDX="" PROBE_KEYB="" PROBE_KEYB_FPR="" PROBE_TREE_STAGED="" PROBE_PREV_STAGED="" PROBE_KEYSET="" PROBE_LOST=""

probe_main() {
    local tree="" inst="" keyset="" prev="" slugs="debian13 ubuntu2604 fedora43 fedora44 opensusetw" steps="p1p2"
    while [ $# -gt 0 ]; do
        case "$1" in
            --tree|--install-dir|--keyset|--prev|--slugs|--steps)
                [ $# -ge 2 ] || probe_die2 "$1 needs a value"
                case "$1" in
                    --tree) tree="$2" ;; --install-dir) inst="$2" ;; --keyset) keyset="$2" ;;
                    --prev) prev="$2" ;; --slugs) slugs="$2" ;; --steps) steps="$2" ;;
                esac
                shift 2 ;;
            *) probe_die2 "usage: $(basename -- "$0") --tree T --install-dir D --keyset K [--prev T] [--slugs S] [--steps S]" ;;
        esac
    done
    [ -n "$tree" ] && [ -d "$tree" ] || probe_die2 "--tree '$tree' is not a directory"
    tree="$(cd -- "$tree" && pwd)"
    [ -n "$inst" ] && [ -d "$inst" ] || probe_die2 "--install-dir '$inst' is not a directory"
    inst="$(cd -- "$inst" && pwd)"
    [ -z "$prev" ] || [ -d "$prev" ] || probe_die2 "--prev '$prev' is not a directory"
    case "$keyset" in rehearsal|package-signing) ;; *) probe_die2 "unknown key set '$keyset'" ;; esac
    PROBE_KEYSET="$keyset"
    local s step forging=0 gens=0
    local -a run=()
    for step in $steps; do
        case "$step" in
            p1p2) run+=("$step") ;;
            forge) run+=(forge-a forge-b forge-c forge-d); forging=1 ;;
            forge-[abcd]) run+=("$step"); forging=1 ;;
            upgrade|key) run+=("$step"); gens=1 ;;
            *) probe_die2 "unknown step '$step' (known: p1p2 forge forge-a forge-b forge-c forge-d upgrade key)" ;;
        esac
    done
    # P3 and P5 need a published generation: without one they are skipped,
    # and say why; one that is there must be a mirror
    if [ "$gens" = 1 ]; then
        local why=""
        if [ -z "$prev" ]; then
            why="no --prev"
        elif [ -f "$prev/EMPTY" ]; then
            why="$(head -n 1 "$prev/EMPTY")"
            why="${why:-EMPTY}"
        elif [ ! -d "$prev/deb" ] && [ ! -d "$prev/rpm" ]; then
            probe_die2 "--prev '$prev' is neither a mirror of a published generation nor EMPTY"
        else
            prev="$(cd -- "$prev" && pwd)"
        fi
        if [ -n "$why" ]; then
            echo "pkg-repo-probe: P3/P5 skipped: no published generation ($why)"
            local -a keep=()
            for step in "${run[@]}"; do case "$step" in upgrade|key) ;; *) keep+=("$step") ;; esac; done
            run=("${keep[@]}")
            gens=0
        fi
    fi
    # The probe job holds no index key: the forgeries that need a valid
    # signature are signed with the probe key, which the clients trust only
    # through the tree's own keyring packages.
    local jobs="${PROBE_FORGE_JOBS:-3}"
    [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || probe_die2 "PROBE_FORGE_JOBS='$jobs' is not a positive integer"
    [ "$forging" = 0 ] || [ "$keyset" = rehearsal ] \
        || probe_die2 "forgeries are signed with the probe key (rehearsal), which the keyring packages of a tree under '$keyset' do not trust"
    local cert="$PROBE_HERE/../keys/$keyset.asc"
    [ -s "$cert" ] || probe_die2 "no certificate $cert"
    [ -f "$tree/KEY.asc" ] || probe_die2 "no KEY.asc in $tree"
    PROBE_IDX="$(sed -n 's/^S_IDX_FPR=\([0-9A-F]\{40\}\)$/\1/p' "$PROBE_HERE/../keys/$keyset.env" 2>/dev/null)"
    [ -n "$PROBE_IDX" ] || probe_die2 "no S_IDX_FPR in keys/$keyset.env"
    if ! cmp -s "$cert" "$tree/KEY.asc"; then
        echo "::error::$tree/KEY.asc is not the certificate of key set '$keyset'"
        exit 1
    fi

    # Every slug's first-contact file, and its URLs, before anything runs.
    PROBE_INST="$inst"
    local bad=0
    for s in $slugs; do
        case "$s" in
            debian13|ubuntu2604|opensusetw) PROBE_FILE[$s]="$s.txt" ;;
            fedora43|fedora44) PROBE_FILE[$s]="fedora.txt" ;;
            *) probe_die2 "'$s' has no first-contact file (known: debian13 ubuntu2604 fedora43 fedora44 opensusetw)" ;;
        esac
        [ -f "$inst/${PROBE_FILE[$s]}" ] || probe_die2 "no $inst/${PROBE_FILE[$s]} for $s"
        PROBE_IMAGE[$s]="$("$PROBE_HERE/pkg-images" get "$s")" || probe_die2 "no image for $s"
        PROBE_MANAGER[$s]="$("$PROBE_HERE/pkg-images" manager "$s")" || probe_die2 "no manager for $s"
        probe_urls "$inst/${PROBE_FILE[$s]}" || bad=1
    done
    # Arch is not probed (the AUR builds from source), but the site quotes
    # install/arch.txt beside the others: its URLs are judged the same way.
    [ -f "$inst/arch.txt" ] || probe_die2 "no $inst/arch.txt"
    probe_urls "$inst/arch.txt" || bad=1
    [ "$bad" = 0 ] || exit 1
    [ "${#run[@]}" -gt 0 ] || exit 0

    trap probe_down EXIT
    trap 'exit 2' HUP INT TERM   # a signal still runs the EXIT trap
    probe_up "$tree" || probe_die2 "the probe network did not come up"

    local verdict=0 rc pass verifier label sum="" i
    PROBE_TREE_STAGED="$PROBE_STAGED"   # the tree itself, as probe_up staged it
    if [ "$gens" = 1 ]; then
        probe_stage "$prev" || probe_die2 "cannot stage the previous generation"
        PROBE_PREV_STAGED="$PROBE_STAGED"
    fi
    [ "$forging" = 0 ] || sum="$(probe_sum "$tree")"
    local -a passes=() todo=()
    for s in $slugs; do
        if [ "$s" = ubuntu2604 ]; then passes+=("$s:gpgv" "$s:sqv"); else passes+=("$s:"); fi
    done
    for step in "${run[@]}"; do
        todo=()
        for pass in "${passes[@]}"; do
            ! probe_forge_applies "$step" "${PROBE_MANAGER[${pass%%:*}]}" || todo+=("$pass")
        done
        [ "${#todo[@]}" -gt 0 ] || continue
        if [ "$step" = upgrade ] || [ "$step" = key ]; then
            PROBE_LOST=""
            rc=0; probe_generation "$step" "$jobs" "$tree" "$prev" "${todo[@]}" || rc=$?
            [ "$rc" = 0 ] || [ "$verdict" = 2 ] || verdict="$rc"
            [ -z "$PROBE_LOST" ] || break   # the server may serve neither tree now
            continue
        fi
        if [ "$step" = p1p2 ]; then
            # one pass after another, each printing as it goes
            for pass in "${todo[@]}"; do
                rc=0; probe_pass "$step" "${pass%%:*}" "${pass#*:}" || rc=$?
                [ "$rc" = 0 ] || [ "$verdict" = 2 ] || verdict="$rc"
            done
            continue
        fi
        # a forgery: made, served, and its passes run up to $jobs at a time,
        # each printed whole when it is done
        echo "-- $step: making the forgery"
        rc=0; probe_forge "$step" "$tree" "$slugs" || rc=$?
        if [ "$rc" = 0 ]; then probe_serve "$PROBE_WORK/$step" || rc=2; fi
        if [ "$rc" != 0 ]; then
            echo "pkg-repo-probe: $step cannot judge (the forgery could not be made or served)"
            verdict=2
            probe_unforge "$step" || break
            continue
        fi
        mkdir -p "$PROBE_WORK/out/$step" || probe_die2 "no $PROBE_WORK/out/$step"
        i=0
        for pass in "${todo[@]}"; do
            [ "$i" -lt "$jobs" ] || { wait -n; i=$((i - 1)); }
            ( rc=0; probe_pass "$step" "${pass%%:*}" "${pass#*:}" >"$PROBE_WORK/out/$step/$pass.log" 2>&1 || rc=$?
              echo "$rc" >"$PROBE_WORK/out/$step/$pass.rc" ) &
            i=$((i + 1))
        done
        wait
        for pass in "${todo[@]}"; do
            cat "$PROBE_WORK/out/$step/$pass.log"
            rc="$(cat "$PROBE_WORK/out/$step/$pass.rc" 2>/dev/null)" || rc=2
            case "$rc" in 0|1) ;; *) rc=2 ;; esac
            [ "$rc" = 0 ] || [ "$verdict" = 2 ] || verdict="$rc"
        done
        probe_unforge "$step" || { verdict=2; break; }
    done
    if [ -n "$sum" ] && [ "$(probe_sum "$tree")" != "$sum" ]; then
        echo "pkg-repo-probe: the forgeries changed the tree they were made from -- cannot judge"
        verdict=2
    fi
    exit "$verdict"
}

# probe_unforge STEP -- the tree itself served again after STEP's forgery, so
# that no later step judges a forgery; 2 when the server will not
probe_unforge() {
    probe_swap "$PROBE_TREE_STAGED" && return 0
    echo "pkg-repo-probe: $1: the tree is not served again after the forgery -- cannot judge"
    return 2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    probe_main "$@"
fi
