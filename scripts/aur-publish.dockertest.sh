#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: linux  (makepkg runs in the archlinux tool image)
# Self-test for aur-publish.sh in `pkg-images tool-image archlinux`, with no
# AUR: the five repositories are local, each with a 1.0.0 tag signed by a
# throw-away key (KEYS is its certificate), a recipe of the real shape
# (git+https://github.com/LibreSCRS/<repo>.git#tag=$pkgver?signed; LibreAgent's
# also an archive with its sha256) and a ci.yml whose actions/gates step gives
# check-recipe the real recipe-args; the AUR is empty bare repositories under
# file:///aur, as the AUR answers a new pkgbase. makepkg reads no user
# gitconfig (it sets GIT_CONFIG_GLOBAL=/dev/null), so the url.insteadOf that
# sends github.com/LibreSCRS/ to file:///fix/ is its MAKEPKG_GIT_CONFIG;
# github.com itself resolves to 127.0.0.1, so a fetch that escapes it fails
# instead of reaching the real repositories. The checkouts belong to root, as
# a runner's belong to another UID than builder.
#
# Cases: the first publish commits exactly PKGBUILD and .SRCINFO as hirashix0
# to every pkgbase; a re-run commits nothing. Each in a fresh copy, nothing
# pushed, and green again with all five pushed once its input is restored
# byte for byte -- red: an unsigned tag, validpgpkeys that is not KEYS, a
# checkout whose recipe is not the one at the signed tag, recipe-args in
# ci.yml the recipe fails, a signed recipe naming another pkgbase; cannot
# judge: a ci.yml with no check-recipe step, with two, one that is not YAML.
# Cannot judge also: an AUR remote that does not answer, root where UID 1000
# is another user, a builder with another UID, bad usage.
#
# Network: the script installs git and openssh with pacman.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ci="$(cd -- "$here/.." && pwd)"
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker is not on PATH -- cannot measure" >&2; exit 2; }
ARCH="$("$here/pkg-images" tool-image archlinux)" || exit 2
work="$(mktemp -d "${TMPDIR:-/var/tmp}/aur-publish-dt.XXXXXX")" || exit 2
tag="aurp-dt-$$"
cleanup() {
    docker ps -aq --filter "name=^$tag-" | xargs -r docker rm -f >/dev/null 2>&1
    rm -rf "$work" 2>/dev/null \
        || { timeout -k 10 120 docker run --rm -v "$work:/w" "$ARCH" find /w -mindepth 1 -delete >/dev/null 2>&1; rm -rf "$work"; }
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM
own="$(id -u):$(id -g)"
log="$work/log"
n=0
run() {  # run SECONDS ARGS... -- one container, with a deadline
    local limit="$1"; shift
    n=$((n + 1))
    timeout -k 30 "$limit" docker run --rm --name "$tag-$n" "$@"
}

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
fact() {  # fact NAME WANT -- the container's "FACT NAME VALUE" line
    local got
    got="$(grep -m 1 "^FACT $1 " "$log" | cut -d' ' -f3-)"
    cases=$((cases + 1))
    if [ "$got" = "$2" ]; then echo "ok   $1: $got"
    else echo "FAIL $1: want '$2', got '$got'"; fail=1; fi
}
fatal() { echo "FATAL: $* -- cannot measure"; tail -n 40 "$log" | sed 's/^/  | /'; exit 2; }
rc_of() { grep -m 1 "^RC $1 " "$log" | cut -d' ' -f3; }

# --- fixture -----------------------------------------------------------------
mkdir -p "$work/t"
cat >"$work/t/fixture.sh" <<'EOF'
set -euo pipefail
timeout -k 10 600 pacman -Sy --noconfirm git >/dev/null
export GNUPGHOME
GNUPGHOME="$(mktemp -d /var/tmp/lg.XXXXXX)"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-gen-key 'aur-publish test key <aur-publish@invalid>' ed25519 sign never
fpr="$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
[ "$(gpg --with-colons --list-secret-keys | grep -c '^sec:')" = 1 ] || { echo "more than the fixture key" >&2; exit 1; }
gpg --armor --export "$fpr" >/w/KEYS
# a second key, never in KEYS
other="$(mktemp -d /var/tmp/lg.XXXXXX)"
GNUPGHOME="$other" gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-gen-key 'aur-publish other key <other@invalid>' ed25519 sign never
GNUPGHOME="$other" gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }' >/w/other.fpr
GNUPGHOME="$other" gpgconf --kill all
qcbor=0123456789abcdef0123456789abcdef01234567
# an archive source beside the signed tag, as the real LibreAgent recipe has
mkdir -p "/var/tmp/qcbor-$qcbor" /w/p/fix
echo qcbor >"/var/tmp/qcbor-$qcbor/README"
tar -C /var/tmp -czf "/w/p/fix/qcbor-$qcbor.tar.gz" "qcbor-$qcbor"
qsum="$(sha256sum "/w/p/fix/qcbor-$qcbor.tar.gz" | cut -d' ' -f1)"
# mk ROOT REPO HEAD SOURCES SUMS FUNCTIONS RECIPE-ARGS -- one source repository
# at ROOT/src/REPO with a signed 1.0.0, and its bare copy at ROOT/fix/REPO.git
mk() {
    local root="$1" r="$2" s="$1/src/$2"
    local -a srcs sums
    read -r -a srcs <<<"$4"
    read -r -a sums <<<"$5"
    mkdir -p "$s/packaging/arch" "$s/.github/workflows" "$root/fix"
    git -C "$s" init -q -b main
    echo 1.0.0 >"$s/VERSION"
    command cp -f /w/KEYS "$s/KEYS"
    {
        printf '%s\n' "$3" 'pkgver=1.0.0' 'pkgrel=1' "pkgdesc='aur-publish fixture'" "arch=('x86_64')" \
            "url='https://github.com/LibreSCRS/$r'" "license=('LGPL-2.1-or-later')"
        [ "$r" != LibreAgent ] || echo "_qcbor_commit=$qcbor"
        printf 'source=(\n'; printf '    "%s"\n' "${srcs[@]}"; printf ')\n'
        echo "validpgpkeys=('$fpr')"
        printf 'sha256sums=(\n'; printf "    '%s'\n" "${sums[@]}"; printf ')\n'
        printf '%s\n' "$6"
    } >"$s/packaging/arch/PKGBUILD"
    {
        printf '%s\n' 'name: CI' 'on: [push]' 'jobs:' '  gates:' '    runs-on: ubuntu-24.04' \
            '    timeout-minutes: 20' '    steps:' '      - name: Shared gates' \
            '        uses: LibreSCRS/ci/actions/gates@0000000000000000000000000000000000000000' \
            '        with:' '          gates: check-workflows check-recipe'
        [ -z "$7" ] || printf '          recipe-args: %s\n' "$7"
    } >"$s/.github/workflows/ci.yml"
    if [ "$r" = LibreAgent ]; then
        mkdir -p "$s/cmake"
        printf 'FetchContent_Declare(qcbor\n    GIT_REPOSITORY https://github.com/laurencelundblade/QCBOR.git\n    GIT_TAG %s\n)\n' "$qcbor" >"$s/cmake/FetchQCBOR.cmake"
    fi
    git -C "$s" add -A
    git -C "$s" -c user.name=fixture -c user.email=fixture@invalid -c commit.gpgsign=false commit -q -m "$r 1.0.0"
    git -C "$s" -c user.signingkey="$fpr" -c user.name=fixture -c user.email=fixture@invalid \
        tag -s -u "$fpr!" -m "$r 1.0.0" 1.0.0
    git -C "$s" verify-tag 1.0.0 2>/dev/null
    git clone -q --bare "$s" "$root/fix/$r.git"
}
pkg='package() { :; }'
fns() { local f=""; for p in "$@"; do f+="package_$p() { :; }"$'\n'; done; printf '%s' "$f"; }
mk /w/p LibreMiddleware 'pkgname=librescrs-middleware' \
    'git+https://github.com/LibreSCRS/LibreMiddleware.git#tag=$pkgver?signed' SKIP "$pkg" \
    '--p11kit-option LIBREMIDDLEWARE_INSTALL_P11KIT_MODULE'
mk /w/p LibreAgent "$(printf '%s\n' 'pkgbase=libreagent' "pkgname=('librescrs-agent-common' 'librescrs-agent-core')" '_srcname=LibreAgent')" \
    '$_srcname::git+https://github.com/LibreSCRS/LibreAgent.git#tag=$pkgver?signed qcbor-$_qcbor_commit.tar.gz::file:///fix/qcbor-$_qcbor_commit.tar.gz' \
    "SKIP $qsum" "$(fns librescrs-agent-common librescrs-agent-core)" \
    '--pin _qcbor_commit=cmake/FetchQCBOR.cmake'
mk /w/p LibreLinux "$(printf '%s\n' 'pkgbase=librelinux' "pkgname=('librescrs-agent' 'librescrs-pinentry-kde')")" \
    'LibreLinux-$pkgver::git+https://github.com/LibreSCRS/LibreLinux.git#tag=$pkgver?signed' SKIP \
    "$(fns librescrs-agent librescrs-pinentry-kde)" "--srcname 'LibreLinux-\$pkgver'"
mk /w/p LibreCelik 'pkgname=librecelik' \
    'git+https://github.com/LibreSCRS/LibreCelik.git#tag=$pkgver?signed' SKIP "$pkg" ''
mk /w/p LibreKDE 'pkgname=librekde' \
    'git+https://github.com/LibreSCRS/LibreKDE.git#tag=$pkgver?signed' SKIP "$pkg" ''
# the same repository, signed alike, whose recipe names another pkgbase
mk /w/p/alt LibreKDE 'pkgname=librekde-renamed' \
    'git+https://github.com/LibreSCRS/LibreKDE.git#tag=$pkgver?signed' SKIP "$pkg" ''
mkdir -p /w/p/aur
for b in librescrs-middleware libreagent librelinux librecelik librekde; do git init -q --bare "/w/p/aur/$b.git"; done
printf '[url "file:///fix/"]\n\tinsteadOf = https://github.com/LibreSCRS/\n' >/w/p/gitconfig
gpgconf --kill all
chown -R "$OWN" /w
EOF

# Each case starts from a copy of the fixture: sources owned by root, the
# fetched repositories and the AUR by builder's UID.
cat >"$work/t/lib.sh" <<'EOF'
PKGBASES=(librescrs-middleware libreagent librelinux librecelik librekde)
fresh() {  # git first: a perturbation made without it changes nothing
    command -v git >/dev/null || timeout -k 10 600 pacman -Sy --noconfirm git >/dev/null || echo "FACT git missing"
    rm -rf /src /fix /aur
    command cp -a /p/src /src && command cp -a /p/fix /fix && command cp -a /p/aur /aur
    chown -R 0:0 /src && chown -R 1000:1000 /fix /aur
}
publish() {  # publish LABEL
    MAKEPKG_GIT_CONFIG=/p/gitconfig bash /ci/scripts/aur-publish.sh --sources /src --remote-base "${REMOTE:-file:///aur}"
    echo "RC $1 $?"
}
heads() {  # heads LABEL -- the master of every AUR repository, or "none"
    local b h out=""
    for b in "${PKGBASES[@]}"; do
        h="$(git --git-dir="/aur/$b.git" rev-parse -q --verify refs/heads/master)" || h=none
        out+="$b=$h "
    done
    echo "FACT $1 ${out% }"
}
pushed() {  # pushed LABEL -- how many AUR repositories have a master
    local b c=0
    for b in "${PKGBASES[@]}"; do
        git --git-dir="/aur/$b.git" rev-parse -q --verify refs/heads/master >/dev/null && c=$((c + 1))
    done
    echo "FACT $1 $c"
}
same() {  # same LABEL A B -- cmp; two empty reads are not "same"
    if [ ! -s "$2" ] || [ ! -s "$3" ]; then echo "FACT $1 unread"
    elif cmp -s "$2" "$3"; then echo "FACT $1 same"; else echo "FACT $1 differs"; fi
}
export -f publish
EOF

echo "-- fixture (archlinux)"
run 900 -e OWN="$own" -v "$work:/w" "$ARCH" bash /w/t/fixture.sh >"$log" 2>&1 \
    || fatal "the fixture did not build"
for r in LibreMiddleware LibreAgent LibreLinux LibreCelik LibreKDE; do
    [ -s "$work/p/src/$r/packaging/arch/PKGBUILD" ] && [ -s "$work/p/src/$r/.github/workflows/ci.yml" ] \
        && [ -d "$work/p/fix/$r.git" ] || fatal "fixture $r is missing"
done
if ! { [ -d "$work/p/alt/fix/LibreKDE.git" ] && ls "$work"/p/fix/qcbor-*.tar.gz >/dev/null 2>&1; }; then
    fatal "fixture alt or archive is missing"
fi
[ -s "$work/KEYS" ] && [ -s "$work/other.fpr" ] || fatal "fixture keys are missing"
# a hash of the whole fixture, so no case can have changed what the next one copies
fixture_sum() { (cd "$work/p" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
sum0="$(fixture_sum)"

case_run() {  # case_run SECONDS BODY -- BODY runs as root after lib.sh
    run "$1" --add-host github.com:127.0.0.1 -v "$work/p:/p:ro" -v "$work/t:/t:ro" -v "$ci:/ci:ro" "$ARCH" \
        bash -c ". /t/lib.sh; $2" >"$log" 2>&1
    ! grep -q '^FACT git missing' "$log" || fatal "git did not install in the case container"
}

# 1, 2. first publish, then a re-run
# shellcheck disable=SC2016  # expanded by the container's shell
case_run 1800 '
fresh
publish first
heads h1
for b in "${PKGBASES[@]}"; do
    g="/aur/$b.git"
    echo "FACT n-$b $(git --git-dir="$g" rev-list --count master 2>/dev/null)"
    echo "FACT who-$b $(git --git-dir="$g" log -1 --format="%an <%ae>|%cn <%ce>" master 2>/dev/null)"
    echo "FACT files-$b $(git --git-dir="$g" ls-tree --name-only master 2>/dev/null | tr "\n" " ")"
    echo "FACT srcinfo-$b $(git --git-dir="$g" show master:.SRCINFO 2>/dev/null | sed -n "s/^pkgbase = //p")"
done
for r in LibreMiddleware:librescrs-middleware LibreAgent:libreagent LibreLinux:librelinux LibreCelik:librecelik LibreKDE:librekde; do
    git --git-dir="/aur/${r#*:}.git" show master:PKGBUILD >/tmp/pb 2>/dev/null
    same "pkgbuild-${r#*:}" /tmp/pb "/src/${r%%:*}/packaging/arch/PKGBUILD"
done
publish again
heads h2
'
expect "1. first publish" 0 "$(rc_of first)" "aur-publish: 5 pushed, 0 unchanged"
for b in librescrs-middleware libreagent librelinux librecelik librekde; do
    fact "n-$b" 1
    fact "who-$b" "hirashix0 <hirashix0@proton.me>|hirashix0 <hirashix0@proton.me>"
    fact "files-$b" ".SRCINFO PKGBUILD "
    fact "srcinfo-$b" "$b"
    fact "pkgbuild-$b" same
done
grep -q 'Verifying source file signatures' "$log" || { echo "FAIL 1. makepkg never verified a signature"; fail=1; }
grep -qE '\[libreagent\] +qcbor-[0-9a-f]{40}\.tar\.gz \.\.\. Passed' "$log" \
    || { echo "FAIL 1. the archive source beside the tag was not fetched and checked"; fail=1; }
cases=$((cases + 1))
h1="$(grep -m 1 '^FACT h1 ' "$log" | cut -d' ' -f3-)"
case "$h1" in *none*|'') echo "FAIL 1. not every pkgbase has a master: $h1"; fail=1 ;; esac
expect "2. a re-run" 0 "$(rc_of again)" "aur-publish: 0 pushed, 5 unchanged"
fact h2 "$h1"

# red_case PERTURB CHECK RESTORE -- each in a fresh copy: the run with the
# perturbation (PERTURB prints FACT <label>-perturbed differs), nothing pushed;
# RESTORE, then CHECK prints FACT <label>-restored same, and the next run is
# green and pushes all five.
red_case() {
    case_run 1800 "
fresh
$1
publish red
pushed red-pushed
$3
$2
publish green
pushed green-pushed
"
}
# judged NAME LABEL WANT TEXT -- the verdicts of one red_case
judged() {
    fact "$2-perturbed" differs
    expect "$1" "$3" "$(rc_of red)" "$4"
    fact red-pushed 0
    fact "$2-restored" same
    expect "$1, restored" 0 "$(rc_of green)" "aur-publish: 5 pushed, 0 unchanged"
    fact green-pushed 5
}
# a file case: PERTURB edits FILE in /src; RESTORE copies the pristine one back
file_case() {  # file_case LABEL FILE PERTURB
    red_case "$3
same $1-perturbed /src/$2 /p/src/$2" "same $1-restored /src/$2 /p/src/$2" "command cp -f /p/src/$2 /src/$2"
}

# 3. the tag recreated without a signature
# shellcheck disable=SC2016  # expanded by the container's shell
red_case '
k=/fix/LibreKDE.git
git --git-dir=$k cat-file -p refs/tags/1.0.0 | grep -c "BEGIN PGP SIGNATURE" | sed "s/^/FACT sig-before /"
git --git-dir=$k -c user.name=x -c user.email=x@invalid tag -f -a -m unsigned 1.0.0 "1.0.0^{commit}" >/dev/null
git --git-dir=$k cat-file -p refs/tags/1.0.0 | grep -c "BEGIN PGP SIGNATURE" | sed "s/^/FACT sig-after /"
git --git-dir=$k cat-file -p refs/tags/1.0.0 >/tmp/a; git --git-dir=/p/fix/LibreKDE.git cat-file -p refs/tags/1.0.0 >/tmp/b
same tag-perturbed /tmp/a /tmp/b
' '
git --git-dir=/fix/LibreKDE.git cat-file -p refs/tags/1.0.0 >/tmp/a
git --git-dir=/p/fix/LibreKDE.git cat-file -p refs/tags/1.0.0 >/tmp/b
same tag-restored /tmp/a /tmp/b
' '
rm -rf /fix/LibreKDE.git && command cp -a /p/fix/LibreKDE.git /fix/ && chown -R 1000:1000 /fix/LibreKDE.git
'
fact sig-before 1
fact sig-after 0
judged "3. an unsigned tag" tag 1 "::error::aur-publish: librekde: makepkg --verifysource: the tag's signature did not verify"

# 4. validpgpkeys names a key KEYS does not hold
other="$(head -n 1 "$work/other.fpr")"
file_case keys LibreLinux/packaging/arch/PKGBUILD \
    "sed -i 's/^validpgpkeys=.*/validpgpkeys=(\x27$other\x27)/' /src/LibreLinux/packaging/arch/PKGBUILD"
judged "4. validpgpkeys is not KEYS" keys 1 "::error::aur-publish: librelinux: check-recipe is red for LibreLinux"
grep -qF '[librelinux] FAIL   trust: validpgpkeys names' "$log" || { echo "FAIL 4. check-recipe was red for another reason"; fail=1; }

# 5. the checkout's recipe is not the tagged one (check-recipe cannot see it)
file_case recipe LibreCelik/packaging/arch/PKGBUILD 'echo "# not in the tag" >>/src/LibreCelik/packaging/arch/PKGBUILD'
judged "5. a recipe that is not the tagged one" recipe 1 \
    "::error::aur-publish: librecelik: packaging/arch/PKGBUILD in /src/LibreCelik is not the one at the signed tag 1.0.0"
grep -qF 'check-recipe: LibreCelik GREEN' "$log" || { echo "FAIL 5. check-recipe was not green, so the case proves nothing"; fail=1; }

# 6. the tag's own ci.yml gives recipe-args the recipe fails
file_case ciargs LibreLinux/.github/workflows/ci.yml "sed -i 's/LibreLinux-/Wrong-/' /src/LibreLinux/.github/workflows/ci.yml"
judged "6. recipe-args from ci.yml that the recipe fails" ciargs 1 "::error::aur-publish: librelinux: check-recipe is red for LibreLinux"
if ! { grep -qF "aur-publish: librelinux: recipe-args from LibreLinux's ci.yml: '--srcname 'Wrong-\$pkgver''" "$log" \
    && grep -qF "[librelinux] FAIL   own: the local name is 'LibreLinux-\$pkgver', not 'Wrong-\$pkgver'" "$log"; }; then
    echo "FAIL 6. check-recipe was not red for the --srcname read from ci.yml"; fail=1
fi

# 7. no actions/gates step runs check-recipe
file_case nostep LibreKDE/.github/workflows/ci.yml "sed -i 's/ check-recipe\$//' /src/LibreKDE/.github/workflows/ci.yml"
judged "7. ci.yml with no check-recipe step" nostep 2 \
    "aur-publish: librekde: recipe-args: /src/LibreKDE/.github/workflows/ci.yml: 0 actions/gates steps run check-recipe; exactly one is needed -- cannot judge"

# 8. two of them
file_case twostep LibreCelik/.github/workflows/ci.yml "printf '%s\n' '      - name: Shared gates again' \
    '        uses: LibreSCRS/ci/actions/gates@0000000000000000000000000000000000000000' \
    '        with:' '          gates: check-recipe' >>/src/LibreCelik/.github/workflows/ci.yml"
judged "8. ci.yml with two check-recipe steps" twostep 2 \
    "aur-publish: librecelik: recipe-args: /src/LibreCelik/.github/workflows/ci.yml: 2 actions/gates steps run check-recipe (jobs gates, gates); exactly one is needed -- cannot judge"

# 9. a ci.yml that is not YAML
file_case badyaml LibreMiddleware/.github/workflows/ci.yml "echo 'jobs: [' >>/src/LibreMiddleware/.github/workflows/ci.yml"
judged "9. ci.yml that does not parse" badyaml 2 \
    "aur-publish: librescrs-middleware: recipe-args: /src/LibreMiddleware/.github/workflows/ci.yml cannot be read as YAML"

# 10. a signed tag whose recipe names another pkgbase
# shellcheck disable=SC2016  # expanded by the container's shell
red_case '
rm -rf /src/LibreKDE /fix/LibreKDE.git
command cp -a /p/alt/src/LibreKDE /src/ && command cp -a /p/alt/fix/LibreKDE.git /fix/ && chown -R 1000:1000 /fix/LibreKDE.git
same pkgbase-perturbed /src/LibreKDE/packaging/arch/PKGBUILD /p/src/LibreKDE/packaging/arch/PKGBUILD
' '
same pkgbase-restored /src/LibreKDE/packaging/arch/PKGBUILD /p/src/LibreKDE/packaging/arch/PKGBUILD
' '
rm -rf /src/LibreKDE /fix/LibreKDE.git
command cp -a /p/src/LibreKDE /src/ && command cp -a /p/fix/LibreKDE.git /fix/ && chown -R 1000:1000 /fix/LibreKDE.git
'
judged "10. a recipe whose pkgbase is not the AUR repository's" pkgbase 1 \
    "::error::aur-publish: librekde: the recipe's pkgbase is 'librekde-renamed', not librekde"

# 11. the remote cannot be reached; root without a builder it can use
# shellcheck disable=SC2016  # expanded by the container's shell
case_run 1200 '
fresh
useradd -m -u 1000 someone
publish taken
pushed taken-pushed
userdel -r someone 2>/dev/null
useradd -m -u 1001 builder
publish wronguid
pushed wronguid-pushed
userdel -r builder 2>/dev/null
REMOTE=file:///nowhere publish unreachable
pushed unreachable-pushed
'
expect "11a. an AUR remote that does not answer" 2 "$(rc_of unreachable)" \
    "aur-publish: librescrs-middleware: git clone of file:///nowhere/librescrs-middleware.git failed (rc 128)"
fact unreachable-pushed 0
expect "11b. root, UID 1000 is another user" 2 "$(rc_of taken)" "no user builder, and UID 1000 is taken by 'someone'"
fact taken-pushed 0
expect "11c. root, builder with UID 1001" 2 "$(rc_of wronguid)" "the user builder exists with UID 1001, not 1000"
fact wronguid-pushed 0

# 12. usage (no container)
mkdir -p "$work/empty"
bash "$here/aur-publish.sh" --remote-base file:///aur >"$log" 2>&1
expect "12a. no --sources" 2 $? "usage:"
bash "$here/aur-publish.sh" --sources "$work/p/src" --remote-base ssh://aur@aur.archlinux.org >"$log" 2>&1
expect "12b. an ssh:// remote without --ssh-key" 2 $? "an ssh:// remote needs --ssh-key"
bash "$here/aur-publish.sh" --sources "$work/p/src" --remote-base https://aur.archlinux.org >"$log" 2>&1
expect "12c. an https:// remote (the AUR takes pushes only over SSH)" 2 $? "is not ssh:// or file://"
bash "$here/aur-publish.sh" --sources "$work/empty" --remote-base file:///aur >"$log" 2>&1
expect "12d. a checkout missing" 2 $? "librescrs-middleware: no packaging/arch/PKGBUILD in $work/empty/LibreMiddleware"

cases=$((cases + 1))
if [ "$(fixture_sum)" = "$sum0" ]; then echo "ok   the fixture is as it was built"
else echo "FAIL the fixture changed under the cases"; fail=1; fi

echo "selftest: $cases cases, $red red-proved"
[ "$fail" -eq 0 ] || exit 1
