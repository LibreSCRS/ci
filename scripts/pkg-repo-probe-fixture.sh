#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC2154  # here, work, tag, own and log are the sourcing self-test's
# pkg-repo-probe-fixture.sh -- the fixture builders the probe's Docker
# self-tests share. Sourced, never run: it defines functions and runs nothing.
#
# The packages carry the real names with the same Depends/Recommends as the
# published chain (debs built in the debian13 image, rpms in each rpm slug's
# own image); the keyring packages are built like the packages repository's,
# carrying FX/cert.asc. A tree is made by pkg-repo.py assemble + sign-index.
#
# The caller sets: here (this directory), work (its temporary directory), tag
# (the prefix of its container names), own (uid:gid), log (a log file), and
# defines fatal MESSAGE (exits).
#
#   fx_packages FX VERSION KVERSION [VARIANT...]
#       debs and rpms (unsigned) into FX/deb/<Repo>/ and FX/rpm/<Repo>/: the
#       code packages at VERSION, the keyring packages at KVERSION. FX/cert.asc
#       is the certificate the keyring packages carry. Variants, each in a
#       directory of its own:
#         norec       a librecelik without Recommends (deb and rpm)
#         nopkgcheck  the opensusetw release package without pkg_gpgcheck=1
#         noskip      the Fedora release packages without skip_if_unavailable
#         unreach     a librecelik that depends on a package nothing provides
#   fx_sign CI FX
#       the rpms of FX signed with CI's pkg-sign.sh --keyset rehearsal: all but
#       the variants in one directory (each image signs once), each variant in
#       its own
#   fx_in IN FX VERSION KVERSION VARIANT
#       FX's packages into the assemble input IN (<Repo>/<tag>/), as release
#       VERSION of every code repository and KVERSION of packages (- leaves
#       packages out). VARIANT good | norec | nokde (no librekde metapackage) |
#       nopkgcheck | noskip | unreach
#   fx_tree CI IN OUT [PREV]
#       assemble IN (carrying PREV) and sign the indexes, with CI's scripts and
#       its rehearsal key set
#   fx_ci CI KEYDIR
#       a copy of this checkout's scripts at CI/scripts whose keys/rehearsal.*
#       are KEYDIR's: the same code under another key set
#   fx_install DIR
#       the first-contact texts (the packages repository's install/*.txt)
#
# The install texts and the keyring recipes here mirror LibreSCRS/packages
# (install/, packaging/) as a model; the publisher's probe always judges the
# real ones, from that repository, never these.
#
# Every container step has a deadline (FX_TIMEOUT, default 1800 s): past it
# the fixture cannot be built, and says which step.

fx_scripts() {
    [ ! -f "$work/deb.sh" ] || return 0
    cat >"$work/deb.sh" <<'EOF'
set -euo pipefail
# the binary form of the certificate, for Signed-By (a .pgp keyring is binary)
sed '1,/^$/d; /^=/,$d' /w/cert.asc | base64 -d >/tmp/keyring.pgp
mk() {  # mk REPO SLUG PACKAGE ARCH VERSION [control lines...]
    local repo=$1 slug=$2 pkg=$3 arch=$4 ver=$5; shift 5
    local d; d=$(mktemp -d); mkdir -p "$d/DEBIAN"
    { printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@invalid>\n' "$pkg" "$ver" "$arch"
      [ $# -eq 0 ] || printf '%s\n' "$@"
      printf 'Description: probe fixture\n'; } >"$d/DEBIAN/control"
    if [ "$pkg" = librescrs-archive-keyring ]; then
        mkdir -p "$d/usr/share/keyrings" "$d/etc/apt/sources.list.d"
        command cp -f /tmp/keyring.pgp "$d/usr/share/keyrings/librescrs-archive-keyring.pgp"
        printf 'Types: deb\nURIs: https://librescrs.github.io/packages/deb\nSuites: %s\nComponents: main\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/librescrs-archive-keyring.pgp\n' \
            "$CODENAME" >"$d/etc/apt/sources.list.d/librescrs.sources"
    fi
    mkdir -p "/w/deb/$repo"
    dpkg-deb --root-owner-group -Zxz --build "$d" "/w/deb/$repo/${pkg}_${ver//\~/.}_$arch.$slug.deb" >/dev/null
    rm -rf "$d"
}
for slug in debian13 ubuntu2604; do
    case $slug in debian13) s='~deb13' CODENAME=trixie ;; ubuntu2604) s='~ubuntu26.04' CODENAME=resolute ;; esac
    v="$V-1$s"
    mk LibreMiddleware $slug liblibrescrs5 amd64 "$v" "Recommends: librescrs-card-plugins (= $v)"
    mk LibreMiddleware $slug librescrs-card-plugins amd64 "$v" "Depends: liblibrescrs5 (= $v)"
    mk LibreAgent $slug liblibrescrs-agentclient-qt5 amd64 "$v"
    mk LibreLinux $slug librescrs-agent amd64 "$v" \
        "Depends: liblibrescrs5 (>= 5.0), librescrs-card-plugins (>= 5.0), librescrs-pinentry-kde (= $v)"
    mk LibreLinux $slug librescrs-pinentry-kde amd64 "$v"
    mk LibreCelik $slug librecelik amd64 "$v" "Depends: liblibrescrs-agentclient-qt5 (>= 5.0)" \
        "Recommends: librescrs-agent (>= 5.0)"
    case " $VARIANTS " in *" norec "*) mk norec $slug librecelik amd64 "$v" "Depends: liblibrescrs-agentclient-qt5 (>= 5.0)" ;; esac
    case " $VARIANTS " in *" unreach "*) mk unreach $slug librecelik amd64 "$v" \
        "Depends: liblibrescrs-agentclient-qt5 (>= 5.0), librescrs-nothing-provides (>= 5.0)" \
        "Recommends: librescrs-agent (>= 5.0)" ;; esac
    mk LibreKDE $slug librekde all "$v" \
        "Depends: librekde-common (= $v), librekde-plasmoid (= $v), librekde-kio (= $v), librekde-purpose (= $v), librekde-credentials (= $v)"
    mk LibreKDE $slug librekde-common all "$v"
    mk LibreKDE $slug librekde-plasmoid amd64 "$v" "Depends: librekde-common (= $v)" "Recommends: librescrs-agent (>= 5.0)"
    for p in kio purpose credentials; do mk LibreKDE $slug librekde-$p amd64 "$v" "Depends: librekde-common (= $v)"; done
    export CODENAME
    mk packages $slug librescrs-archive-keyring all "$K-1$s"
done
chown -R "$OWN" /w
EOF

    cat >"$work/rpm.sh" <<'EOF'
set -euo pipefail
case "$PKG_MANAGER" in
    dnf)    dnf -y -q install rpm-build >/dev/null ;;
    zypper) zypper -n -q install rpm-build >/dev/null ;;
esac
mk() {  # mk REPO NAME VERSION [spec header lines...]
    local repo=$1 name=$2 ver=$3; shift 3
    rm -rf /b; mkdir -p /b/SPECS
    { printf '%%global debug_package %%{nil}\nName: %s\nVersion: %s\nRelease: 1%%{?dist}\nSummary: probe fixture\nLicense: MIT\n' "$name" "$ver"
      [ $# -eq 0 ] || printf '%s\n' "$@"
      printf '%%description\nprobe fixture\n'
      if [ "$name" = librescrs-release ]; then
          printf '%%install\nmkdir -p %%{buildroot}/etc/pki/rpm-gpg %%{buildroot}%s\n' "$REPODIR"
          printf 'cp /w/cert.asc %%{buildroot}/etc/pki/rpm-gpg/RPM-GPG-KEY-librescrs\n'
          printf 'cp /tmp/librescrs.repo %%{buildroot}%s/librescrs.repo\n' "$REPODIR"
          printf '%%files\n/etc/pki/rpm-gpg/RPM-GPG-KEY-librescrs\n%%config(noreplace) %s/librescrs.repo\n' "$REPODIR"
      else
          printf '%%files\n'
      fi; } >"/b/SPECS/$name.spec"
    rpmbuild --define "_topdir /b" -bb "/b/SPECS/$name.spec" >/tmp/rpmbuild.log 2>&1 || { cat /tmp/rpmbuild.log; exit 1; }
    mkdir -p "/w/rpm/$repo"
    for f in /b/RPMS/*/*.rpm; do command cp -f "$f" "/w/rpm/$repo/$(basename "$f" .rpm).$SLUG.rpm"; done
}
variant() { case " $VARIANTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
I='%{?_isa}'
mk LibreMiddleware librescrs-middleware "$V"
mk LibreMiddleware librescrs-card-plugins "$V" "Requires: librescrs-middleware$I = $V-1%{?dist}"
mk LibreAgent librescrs-agent-client-qt "$V"
mk LibreLinux librescrs-agent "$V" "Requires: librescrs-middleware$I >= 5.0" "Requires: librescrs-card-plugins$I >= 5.0" \
    "Requires: librescrs-pinentry-kde$I = $V-1%{?dist}"
mk LibreLinux librescrs-pinentry-kde "$V"
mk LibreCelik librecelik "$V" "Requires: librescrs-agent-client-qt$I >= 5.0" "Recommends: librescrs-agent >= 5.0"
! variant norec || mk norec librecelik "$V" "Requires: librescrs-agent-client-qt$I >= 5.0"
! variant unreach || mk unreach librecelik "$V" "Requires: librescrs-agent-client-qt$I >= 5.0" \
    "Requires: librescrs-nothing-provides >= 5.0" "Recommends: librescrs-agent >= 5.0"
if [ "$SLUG" != opensusetw ]; then   # LibreKDE is not built for Tumbleweed
    mk LibreKDE librekde "$V" "Requires: librekde-common = $V-1%{?dist}" "Requires: librekde-plasmoid$I = $V-1%{?dist}" \
        "Requires: librekde-kio$I = $V-1%{?dist}" "Requires: librekde-purpose$I = $V-1%{?dist}" \
        "Requires: librekde-credentials$I = $V-1%{?dist}"
    mk LibreKDE librekde-common "$V" "BuildArch: noarch"
    mk LibreKDE librekde-plasmoid "$V" "Requires: librekde-common = $V-1%{?dist}" "Recommends: librescrs-agent >= 5.0"
    for p in kio purpose credentials; do mk LibreKDE librekde-$p "$V" "Requires: librekde-common = $V-1%{?dist}"; done
fi
if [ "$PKG_MANAGER" = zypper ]; then
    REPODIR=/etc/zypp/repos.d
    printf '[librescrs]\nname=LibreSCRS\nbaseurl=https://librescrs.github.io/packages/rpm/opensusetw/\ntype=rpm-md\nenabled=1\nautorefresh=1\ngpgcheck=1\nrepo_gpgcheck=1\npkg_gpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-librescrs\nmetadata_expire=6h\n' >/tmp/librescrs.repo
else
    REPODIR=/etc/yum.repos.d
    printf '[librescrs]\nname=LibreSCRS\nbaseurl=https://librescrs.github.io/packages/rpm/fedora$releasever/\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\npkg_gpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-librescrs\nmetadata_expire=6h\nskip_if_unavailable=True\n' >/tmp/librescrs.repo
fi
export REPODIR
mk packages librescrs-release "$K" "BuildArch: noarch"
if [ "$PKG_MANAGER" = zypper ] && variant nopkgcheck; then
    # the same release package without pkg_gpgcheck=1: zypper then takes an
    # unsigned rpm from a signed index
    sed -i '/^pkg_gpgcheck=1$/d' /tmp/librescrs.repo
    ! grep -q pkg_gpgcheck /tmp/librescrs.repo || { echo "pkg_gpgcheck is still in the .repo"; exit 1; }
    mk nopkgcheck librescrs-release "$K" "BuildArch: noarch"
fi
if [ "$PKG_MANAGER" = dnf ] && variant noskip; then
    # the same release package without skip_if_unavailable=True: dnf then
    # fails on a Fedora the repository has no tree for yet
    sed -i '/^skip_if_unavailable=True$/d' /tmp/librescrs.repo
    ! grep -q skip_if_unavailable /tmp/librescrs.repo || { echo "skip_if_unavailable is still in the .repo"; exit 1; }
    mk noskip librescrs-release "$K" "BuildArch: noarch"
fi
chown -R "$OWN" /w
EOF
}

fx_packages() {
    local fx="$1" v="$2" k="$3" slug; shift 3
    local variants="$*" d13
    fx_scripts
    [ -s "$fx/cert.asc" ] || fatal "no $fx/cert.asc for the keyring packages"
    mkdir -p "$fx/deb" "$fx/rpm"
    d13="$("$here/pkg-images" get debian13)" || fatal "no debian13 image"
    echo "-- fixture: debs $v (keyring $k) in $fx"
    timeout -s KILL "${FX_TIMEOUT:-1800}" docker run --rm --name "$tag-deb" -v "$fx:/w" -v "$work/deb.sh:/deb.sh:ro" -e "OWN=$own" -e "V=$v" -e "K=$k" \
        -e "VARIANTS=$variants" "$d13" bash /deb.sh >"$log" 2>&1 || fatal "the fixture debs do not build"
    for slug in fedora43 fedora44 opensusetw; do
        echo "-- fixture: rpms $v (release $k) for $slug in $fx"
        timeout -s KILL "${FX_TIMEOUT:-1800}" docker run --rm --name "$tag-rpm-$slug" -v "$fx:/w" -v "$work/rpm.sh:/rpm.sh:ro" -e "OWN=$own" -e "SLUG=$slug" \
            -e "V=$v" -e "K=$k" -e "VARIANTS=$variants" \
            -e "PKG_MANAGER=$("$here/pkg-images" manager "$slug")" "$("$here/pkg-images" get "$slug")" bash /rpm.sh >"$log" 2>&1 \
            || fatal "the fixture rpms for $slug do not build"
    done
}

fx_isvariant() { case "$1" in */norec/*|*/nopkgcheck/*|*/noskip/*|*/unreach/*) return 0 ;; *) return 1 ;; esac; }

fx_sign() {
    local ci="$1" fx="$2" f d
    echo "-- fixture: sign the rpms of $fx with $ci's rehearsal key set"
    mkdir -p "$fx/sign"
    for f in "$fx"/rpm/*/*.rpm; do fx_isvariant "$f" || command cp -f "$f" "$fx/sign/"; done
    for d in "$fx/sign" "$fx"/rpm/norec "$fx"/rpm/nopkgcheck "$fx"/rpm/noskip "$fx"/rpm/unreach; do
        [ -d "$d" ] || continue
        timeout -k 60 "${FX_TIMEOUT:-1800}" "$ci/scripts/pkg-sign.sh" --dir "$d" --keyset rehearsal >"$log" 2>&1 \
            || fatal "pkg-sign.sh cannot sign $d"
    done
    for f in "$fx"/rpm/*/*.rpm; do fx_isvariant "$f" || command cp -f "$fx/sign/$(basename "$f")" "$f"; done
    rm -rf "${fx:?}/sign"
}

fx_in() {
    local in="$1" fx="$2" v="$3" k="$4" variant="$5" r f n t
    for r in LibreMiddleware LibreAgent LibreLinux LibreCelik LibreKDE packages; do
        t="$v"
        if [ "$r" = packages ]; then [ "$k" != - ] || continue; t="$k"; fi
        mkdir -p "$in/$r/$t"
        for f in "$fx"/deb/"$r"/* "$fx"/rpm/"$r"/*; do
            [ -f "$f" ] || continue
            n="$(basename "$f")"
            case "$variant:$n" in
                norec:librecelik[_-]*) f="$(dirname "$f")/../norec/$n" ;;
                nokde:librekde_*|nokde:librekde-[0-9]*) continue ;;
                nopkgcheck:librescrs-release-*.opensusetw.rpm) f="$(dirname "$f")/../nopkgcheck/$n" ;;
                noskip:librescrs-release-*.fedora4[0-9].rpm) f="$(dirname "$f")/../noskip/$n" ;;
                unreach:librecelik[_-]*) f="$(dirname "$f")/../unreach/$n" ;;
            esac
            command cp -f "$f" "$in/$r/$t/$n" || fatal "no $f"
        done
    done
    [ "$k" = - ] || printf 'probe fixture KEYS\n' >"$in/packages/$k/KEYS"
}

fx_tree() {
    local ci="$1" in="$2" out="$3" prev="${4:-}"
    echo "-- fixture: tree $(basename "$out")${prev:+ (carrying $(basename "$prev"))}"
    timeout -k 60 "${FX_TIMEOUT:-1800}" python3 -I "$ci/scripts/pkg-repo.py" assemble --in "$in" --out "$out" --now "$(date +%s)" \
        --valid-days 30 --keyset rehearsal ${prev:+--prev "$prev"} >"$log" 2>&1 || fatal "assemble of $out"
    timeout -k 60 "${FX_TIMEOUT:-1800}" python3 -I "$ci/scripts/pkg-repo.py" sign-index --tree "$out" --keyset rehearsal >"$log" 2>&1 \
        || fatal "sign-index of $out"
}

fx_ci() {
    local ci="$1" keys="$2" n
    rm -rf "${ci:?}/scripts"
    mkdir -p "$ci/scripts" "$ci/keys" || fatal "no $ci"
    command cp -a "$here/." "$ci/scripts/" || fatal "cannot copy the scripts to $ci"
    command cp -f "$here/../images.lock" "$ci/images.lock" || fatal "no images.lock"
    for n in asc sec.asc env; do
        command cp -f "$keys/rehearsal.$n" "$ci/keys/rehearsal.$n" || fatal "no $keys/rehearsal.$n"
    done
}

fx_install() {
    local inst="$1" c
    mkdir -p "$inst"
    for c in debian13:trixie ubuntu2604:resolute; do
        cat >"$inst/${c%%:*}.txt" <<EOF
wget https://librescrs.github.io/packages/librescrs-archive-keyring-${c#*:}.deb
sudo apt install ./librescrs-archive-keyring-${c#*:}.deb
sudo apt update
sudo apt install librecelik
EOF
    done
    cat >"$inst/fedora.txt" <<'EOF'
sudo dnf install https://librescrs.github.io/packages/librescrs-release-fedora.noarch.rpm
sudo dnf install librecelik
EOF
    cat >"$inst/opensusetw.txt" <<'EOF'
curl -fLO https://librescrs.github.io/packages/KEY.asc
gpg --show-keys --with-fingerprint KEY.asc
sudo rpm --import KEY.asc
sudo zypper install https://librescrs.github.io/packages/librescrs-release-opensusetw.noarch.rpm
sudo zypper install librecelik
EOF
    cat >"$inst/arch.txt" <<'EOF'
curl -fLO https://librescrs.github.io/packages/KEYS
gpg --show-keys --with-fingerprint KEYS
gpg --import KEYS
yay -S librecelik
EOF
}
