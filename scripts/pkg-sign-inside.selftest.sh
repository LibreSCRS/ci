#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-sign-inside.selftest.sh -- the package install in pkg-sign-inside.sh
# against stub package managers: one that fails its first install (a mirror
# mid-sync) must be retried after a refresh, one that always fails must still
# end in exit 2, and a verify run installs nothing.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d /var/tmp/pkg-sign-inside-st.XXXXXX)" || exit 2
trap 'rm -rf "$T"' EXIT
bin="$T/bin"; mkdir -p "$bin"
# Every stub logs its argv; the package manager's install fails while
# $T/fail-installs holds a count above zero, decrementing it.
for m in dnf zypper; do
    cat >"$bin/$m" <<EOS
#!/usr/bin/env bash
echo "$m \$*" >>"$T/calls"
case " \$* " in
    *" install "*)
        n=\$(cat "$T/fail-installs"); [ "\$n" -gt 0 ] || exit 0
        echo \$((n - 1)) >"$T/fail-installs"; exit 1 ;;
esac
exit 0
EOS
done
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/rpmkeys"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/gpg"
chmod +x "$bin"/*
: >"$T/cert"; : >"$T/key"

n=0 r=0 fail=0
# run NAME WANT-RC FAILS MANAGER MODE [COUNT-INSTALLS WANT]
run() {
    local name=$1 want=$2 fails=$3 mgr=$4 mode=$5 installs=${6:-} wantn=${7:-} got c
    : >"$T/calls"; echo "$fails" >"$T/fail-installs"
    PATH="$bin:$PATH" PKG_SIGN_RETRY_SLEEP=0 MODE=$mode PKG_MANAGER=$mgr CERT="$T/cert" SIGNER=ABCDEF0123456789 \
        SIGN_KEY="$T/key" bash "$here/pkg-sign-inside.sh" >"$T/out" 2>&1 </dev/null; got=$?
    c="$(grep -c " install " "$T/calls")"
    n=$((n + 1))
    if [ "$got" = "$want" ] && { [ -z "$installs" ] || [ "$c" = "$wantn" ]; }; then
        [ "$want" = 0 ] || r=$((r + 1))
        echo "ok   $name (rc=$got, $c install attempts)"
    else
        fail=1; echo "FAIL $name: want rc=$want and ${wantn:-any} installs, got rc=$got and $c"; sed 's/^/     | /' "$T/out"
    fi
}
for m in zypper dnf; do
    run "$m: installs at once, no refresh" 0 0 $m sign x 1
    n=$((n + 1))
    if ! grep -q -e " refresh" -e " makecache" "$T/calls"; then echo "ok   $m: ...and no refresh was run"; else fail=1; echo "FAIL $m: refreshed without a failure"; fi
    run "$m: a mirror mid-sync (first install fails) is retried and succeeds" 0 1 $m sign x 2
    n=$((n + 1))
    if grep -q -e " refresh" -e " makecache" "$T/calls"; then echo "ok   $m: ...after a refresh"; else fail=1; echo "FAIL $m: no refresh between attempts"; fi
    run "$m: two failures, third attempt succeeds" 0 2 $m sign x 3
    run "$m: always failing install still exits 2 after three attempts" 2 99 $m sign x 3
    run "$m: verify mode installs nothing" 0 99 $m verify x 0
done
echo "selftest: $n cases, $r red-proved"
exit "$fail"
