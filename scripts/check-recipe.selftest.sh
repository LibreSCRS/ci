#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# check-recipe.selftest.sh -- a green control recipe, then one perturbation per
# rule; each must turn the gate red (1) or unjudgeable (2) and say why.
# Fixtures are throw-away checkouts; the release key is generated here.
# shellcheck disable=SC2016  # the recipes' literal $pkgver is the subject here
set -uo pipefail
unset REPO_ROOT GITHUB_WORKSPACE GITHUB_REPOSITORY
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GATE="$here/check-recipe"
command -v gpg >/dev/null 2>&1 || { echo "FATAL: gpg is not on PATH -- cannot run" >&2; exit 2; }
W="$(mktemp -d "/var/tmp/check-recipe-st.XXXXXX")" || exit 2
trap 'GNUPGHOME="$W/gnupg" gpgconf --kill all >/dev/null 2>&1; rm -rf "$W"' EXIT
cases=0 red=0 fails=0

mkdir -m 700 "$W/gnupg"
GNUPGHOME="$W/gnupg" gpg --batch --passphrase '' --quick-gen-key "Selftest Release <release@invalid>" ed25519 cert 1d >/dev/null 2>&1 || exit 2
FPR="$(GNUPGHOME="$W/gnupg" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
GNUPGHOME="$W/gnupg" gpg --batch --armor --export >"$W/KEYS" 2>/dev/null
GNUPGHOME="$W/gnupg" gpgconf --kill all >/dev/null 2>&1
[ -n "$FPR" ] && [ -s "$W/KEYS" ] || { echo "FATAL: no release key" >&2; exit 2; }
QC=930708bb86481e88879eb1d87fd4d664f1d69503
SUB=01346829096c61b372692f6dc43ffa778c6caccd
SUM=0da68ac55f6e67c67e57f4fe4603b850713ce2b0ac95fb76094f446139db4d57

# fixture <name>: a consumer "Pkg" whose recipe passes every rule with the flags FLAGS.
FLAGS=(--repo Pkg --srcname 'Pkg-$pkgver' --pin _qcbor_commit=cmake/FetchQCBOR.cmake --p11kit-option PKG_INSTALL_P11KIT)
fixture() {
  local d="$W/$1"
  mkdir -p "$d/packaging/arch" "$d/cmake"
  echo 5.0.0 >"$d/VERSION"
  cp "$W/KEYS" "$d/KEYS"
  printf 'FetchContent_Declare(qcbor\n  GIT_TAG %s\n)\n' "$QC" >"$d/cmake/FetchQCBOR.cmake"
  printf '# Pkg\nInstall with makepkg -si.\n' >"$d/packaging/arch/README.md"
  cat >"$d/packaging/arch/PKGBUILD" <<EOF
pkgname=pkg
pkgver=5.0.0
_qcbor_commit=$QC
# the submodule pin $SUB
optdepends=('pcsclite: smart card access')
source=(
    "Pkg-\$pkgver::git+https://github.com/LibreSCRS/Pkg.git#tag=\$pkgver?signed"
    "qcbor-\$_qcbor_commit.tar.gz::https://github.com/laurencelundblade/QCBOR/archive/\$_qcbor_commit.tar.gz"
)
sha256sums=('SKIP'
            '$SUM')
validpgpkeys=('$FPR')  # release key

build() {
  cmake -B build -S "Pkg-\$pkgver"
}
EOF
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" update-index --add --cacheinfo "160000,$SUB,thirdparty/sub"
  echo "$d"
}
edit() { sed -i "$2" "$1/packaging/arch/PKGBUILD"; }

# check <name> <want-rc> <needle> <dir> [extra args...]
check() {
  local name="$1" want="$2" needle="$3" d="$4"; shift 4
  cases=$((cases + 1))
  [ "$want" = 0 ] || red=$((red + 1))
  (cd "$W" && bash "$GATE" --root "$d" "$@") >"$W/out" 2>&1
  local got=$?
  if [ "$got" = "$want" ] && grep -qF -- "$needle" "$W/out"; then
    printf 'ok    %-58s rc=%s\n' "$name" "$got"
  else
    printf 'FAIL  %-58s rc=%s want=%s (needle: %s)\n' "$name" "$got" "$want" "$needle"
    sed 's/^/  | /' "$W/out"
    fails=1
  fi
}

d=$(fixture control)
check "control: every rule green, every rule says what it measured" 0 "check-recipe: Pkg GREEN" "$d" "${FLAGS[@]}"
if ! { grep -q '^pins: _qcbor_commit=' "$W/out" && grep -q '^p11kit: no registration' "$W/out" \
  && grep -q '^trust: 1 VCS source(s) at SKIP, 1 download(s)' "$W/out"; }; then
  echo "FAIL  control does not report every rule"; fails=1
fi

# --- own ---
d=$(fixture v); edit "$d" 's/#tag=\$pkgver?signed/#tag=v$pkgver?signed/'
check "own: a v-prefixed tag" 1 "v-prefixed" "$d" "${FLAGS[@]}"
d=$(fixture arch); edit "$d" 's|"Pkg-\$pkgver::git+https://github.com/LibreSCRS/Pkg.git#tag=\$pkgver?signed"|"pkg.tar.gz::https://github.com/LibreSCRS/Pkg/archive/refs/tags/$pkgver.tar.gz"|'
check "own: GitHub's generated archive of the tag" 1 "auto-generated archive" "$d" "${FLAGS[@]}"
d=$(fixture asset); edit "$d" 's|"Pkg-\$pkgver::git+https://github.com/LibreSCRS/Pkg.git#tag=\$pkgver?signed"|"pkg.tar.gz::https://github.com/LibreSCRS/Pkg/releases/download/$pkgver/pkg.tar.gz"|'
check "own: a release-asset tarball" 1 "release asset" "$d" "${FLAGS[@]}"
d=$(fixture unsigned); edit "$d" 's/#tag=\$pkgver?signed/#tag=$pkgver/'
check "own: the tag without ?signed" 1 "without ?signed" "$d" "${FLAGS[@]}"
d=$(fixture sibling); edit "$d" 's|LibreSCRS/Pkg.git|LibreSCRS/Other.git|'
check "own: a sibling repository's tag" 1 "while this repository is Pkg" "$d" "${FLAGS[@]}"
d=$(fixture branch); edit "$d" 's/#tag=\$pkgver?signed/#branch=main?signed/'
check "own: a branch instead of the tag" 1 "not to the tag" "$d" "${FLAGS[@]}"
d=$(fixture noref); edit "$d" 's/#tag=\$pkgver?signed//'
check "own: no ref at all" 1 "names no ref" "$d" "${FLAGS[@]}"
d=$(fixture srcname); edit "$d" 's/"Pkg-\$pkgver::git/"Pkg::git/'
check "own: a local name build() does not enter (--srcname)" 1 "not 'Pkg-\$pkgver'" "$d" "${FLAGS[@]}"
d=$(fixture twice); edit "$d" '/^source=(/a\    "git+https://github.com/LibreSCRS/Pkg.git#tag=$pkgver?signed"'; edit "$d" "s/^sha256sums=('SKIP'/sha256sums=('SKIP' 'SKIP'/"
check "own: the own source twice" 1 "found 2" "$d" "${FLAGS[@]}"
d=$(fixture vacuum); edit "$d" 's/^source=(/sources=(/'
check "own: source=() renamed, the vacuum" 1 "vacuum" "$d" "${FLAGS[@]}"
d=$(fixture named); GITHUB_REPOSITORY=LibreSCRS/Other check "own: the name comes from GITHUB_REPOSITORY" 1 "while this repository is Other" "$d"

# --- version ---
d=$(fixture drift); echo 5.0.1 >"$d/VERSION"
check "version: pkgver disagrees with VERSION" 1 "VERSION says 5.0.1" "$d" "${FLAGS[@]}"
d=$(fixture nover); rm "$d/VERSION"
check "version: VERSION missing is a failure, not a skip" 1 "VERSION is missing" "$d" "${FLAGS[@]}"

# --- pins ---
d=$(fixture gitlink); git -C "$d" update-index --cacheinfo "160000,1111111111111111111111111111111111111111,thirdparty/sub"
check "pins: a submodule gitlink the recipe does not carry" 1 "appears nowhere in the recipe" "$d" "${FLAGS[@]}"
d=$(fixture pindrift); sed -i "s/$QC/2222222222222222222222222222222222222222/" "$d/cmake/FetchQCBOR.cmake"
check "pins: the FetchContent pin drifts from the recipe" 1 "_qcbor_commit drift" "$d" "${FLAGS[@]}"
d=$(fixture pinless); edit "$d" '/^_qcbor_commit=/d'
check "pins: --pin names a variable the recipe lacks" 1 "carries no _qcbor_commit" "$d" "${FLAGS[@]}"

# --- trust ---
d=$(fixture wrongkey); edit "$d" "s/$FPR/0123456789ABCDEF0123456789ABCDEF01234567/"
check "trust: validpgpkeys names another key" 1 "but KEYS carries $FPR" "$d" "${FLAGS[@]}"
d=$(fixture nokey); edit "$d" '/^validpgpkeys=/d'
check "trust: no validpgpkeys" 1 "no validpgpkeys" "$d" "${FLAGS[@]}"
d=$(fixture dlskip); edit "$d" "s/'$SUM'/'SKIP'/"
check "trust: an archive at a fixed commit left at SKIP" 1 "not its sha256" "$d" "${FLAGS[@]}"
d=$(fixture gitsum); edit "$d" "s/^sha256sums=('SKIP'/sha256sums=('$SUM'/"
check "trust: a sum on the git source" 1 "makepkg refuses a sum there" "$d" "${FLAGS[@]}"
d=$(fixture short); edit "$d" "/^            '$SUM')/d"; edit "$d" "s/^sha256sums=('SKIP'/sha256sums=('SKIP')/"
check "trust: one sum short" 1 "pairs them by position" "$d" "${FLAGS[@]}"

# --- p11kit ---
d=$(fixture readme); echo 'The module is registered in /usr/share/p11-kit/modules/pkg.module.' >>"$d/packaging/arch/README.md"
check "p11kit: README names a registration not installed" 1 "README.md:3 names share/p11-kit/modules" "$d" "${FLAGS[@]}"
d=$(fixture optdep); edit "$d" "s/^optdepends=('pcsclite: smart card access')/optdepends=('pcsclite: smart card access' 'p11-kit: card discovery')/"
check "p11kit: optdepends offers p11-kit" 1 "optdepends offers p11-kit" "$d" "${FLAGS[@]}"
d=$(fixture on); echo 'See /usr/share/p11-kit/modules/pkg.module.' >>"$d/packaging/arch/README.md"; edit "$d" 's/cmake -B build/cmake -DPKG_INSTALL_P11KIT=ON -B build/'
check "p11kit: described AND installed is true" 0 "describing it is true" "$d" "${FLAGS[@]}"

# --- cannot judge ---
d=$(fixture nokeys); rm "$d/KEYS"
check "no KEYS cannot be judged" 2 "no KEYS at" "$d" "${FLAGS[@]}"
d=$(fixture norecipe); rm "$d/packaging/arch/PKGBUILD"
check "no recipe cannot be judged" 2 "no recipe at" "$d" "${FLAGS[@]}"
d=$(fixture emptykeys); : >"$d/KEYS"
check "a KEYS with no key cannot be judged" 2 "no primary key" "$d" "${FLAGS[@]}"
mkdir -p "$W/nogpg"
for t in bash git awk sed grep sort tr mktemp head basename dirname rm cat; do ln -sf "$(command -v "$t")" "$W/nogpg/$t"; done
d=$(fixture nogpg)
PATH="$W/nogpg" check "no gpg on PATH cannot be judged" 2 "gpg is not on PATH" "$d" "${FLAGS[@]}"
check "an unknown option is a usage error" 2 "usage:" "$d" --bogus x

# --- root from the environment, never from this script's place ---
d=$(fixture envroot)
cases=$((cases + 1))
if (cd "$W" && REPO_ROOT="$d" bash "$GATE" "${FLAGS[@]}") >"$W/out" 2>&1; then echo "ok    REPO_ROOT names the checkout"; else echo "FAIL  REPO_ROOT names the checkout"; cat "$W/out"; fails=1; fi

[ "$fails" = 0 ] || { echo "check-recipe selftest: FAILED"; exit 1; }
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
