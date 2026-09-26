#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# pkg-changelog-debian.sh -- write debian/changelog from the consumer's
# CHANGELOG.md and VERSION.
#
# Usage: pkg-changelog-debian.sh <source-package> [output-path]
#        (consumer root: REPO_ROOT, else GITHUB_WORKSPACE, else the git
#        top level of the working directory)
#
# The entry is the release's HEADLINES, not its prose: the bold lead sentence
# of each top-level bullet of the topmost CHANGELOG.md section, whole and
# wrapped at word boundaries. CHANGELOG.md is written for people reading a
# release page; a package changelog is read in a terminal, one line per change.
# Cutting the prose at a fixed column (what the previous generator did) left
# sentences broken in half, and taking the first line of an unbolded bullet
# carried source paths into a public package. A bullet without a bold lead
# contributes nothing; a headline that names an internal path, file or process
# word stops the build, because the fix belongs in CHANGELOG.md.
#
# The date comes from SOURCE_DATE_EPOCH when set (the gate sets it to the
# commit time) and is computed by `date -R`, so the day of week cannot disagree
# with the date (lintian: debian-changelog-has-wrong-day-of-week).
#
# Exit codes: 0 written, 1 a headline names something internal or the section
# is malformed, 2 cannot judge (no VERSION / CHANGELOG.md, no root).
set -uo pipefail

MAINTAINER="LibreSCRS <librescrs@proton.me>"

src="${1:-}"
[ -n "$src" ] || { echo "usage: pkg-changelog-debian.sh <source-package> [output]" >&2; exit 2; }
out="${2:-debian/changelog}"

root="${REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "pkg-changelog-debian: no REPO_ROOT and not in a git checkout" >&2; exit 2; }
[ -f "$root/VERSION" ] && [ -f "$root/CHANGELOG.md" ] \
    || { echo "pkg-changelog-debian: $root has no VERSION or CHANGELOG.md" >&2; exit 2; }

version="$(tr -d '[:space:]' <"$root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([~+.-][0-9A-Za-z.~+-]+)?$ ]] \
    || { echo "pkg-changelog-debian: VERSION '$version' is not a version" >&2; exit 1; }
revision="${DEB_REVISION:-1}"

if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    stamp="$(LC_ALL=C date -R -u -d "@$SOURCE_DATE_EPOCH")"
else
    stamp="$(LC_ALL=C date -R)"
fi

# Headlines: one per top-level bullet of the first "## " section, continuation
# lines joined, markdown links and code ticks dropped, the leading **bold**
# span kept whole.
heads="$(awk '
    function flush() {
        if (cur != "" && match(cur, /^\*\*[^*]+\*\*/)) {
            h = substr(cur, 3, RLENGTH - 4)
            gsub(/\[[^]]*\]\([^)]*\)/, "", h)
            gsub(/`/, "", h); gsub(/[[:space:]]+/, " ", h); sub(/^ /, "", h); sub(/ $/, "", h)
            if (h != "") print h
        }
        cur = ""
    }
    /^## / { if (seen) { flush(); exit } seen = 1; next }
    !seen { next }
    /^[-*] / { flush(); cur = $0; sub(/^[-*] +/, "", cur); next }
    /^[[:space:]]+[^[:space:]]/ { if (cur != "") { l = $0; sub(/^[[:space:]]+/, " ", l); cur = cur l } ; next }
    /^[[:space:]]*$/ { flush(); next }
    { flush() }
    END { flush() }
' "$root/CHANGELOG.md")"

# Internal names: source-tree paths and C++/build files, and the process
# vocabulary release notes must not carry. A user-facing script under tools/
# (the SDK migration helper, say) is not internal and is not matched. Matched on the headline, which is all that ships.
internal='(^|[^[:alnum:]])(src|ci|tests?|knowledge|packaging|cmake)/|\.(cpp|cc|cxx|hpp|h|cmake|yml)([^[:alnum:]]|$)|(^|[^[:alnum:]])([Ww]ave|[Bb]ucket|[Pp]hase|[Bb]acklog|[Ss]quash|project_)([^[:alnum:]]|$)'
bad="$(printf '%s\n' "$heads" | grep -E "$internal" || true)"
if [ -n "$bad" ]; then
    echo "pkg-changelog-debian: headline(s) name something internal -- reword CHANGELOG.md:" >&2
    printf '  %s\n' "$bad" >&2
    exit 1
fi

wrap() {  # "  * " first line, "    " continuation, at most 80 columns
    awk '{
        n = split($0, w, " "); line = "  *"
        for (i = 1; i <= n; i++) {
            if (length(line) + 1 + length(w[i]) > 80 && line != "  *" && line != "   ") { print line; line = "   " }
            line = line " " w[i]
        }
        print line
    }'
}

mkdir -p "$(dirname "$out")"
{
    printf '%s (%s-%s) unstable; urgency=medium\n\n' "$src" "$version" "$revision"
    printf '  * New upstream release %s.\n' "$version"
    [ -z "$heads" ] || printf '%s\n' "$heads" | while IFS= read -r h; do printf '%s\n' "$h" | wrap; done
    printf '\n -- %s  %s\n' "$MAINTAINER" "$stamp"
} >"$out"

echo "pkg-changelog-debian: wrote $out for $src $version-$revision ($(printf '%s' "$heads" | grep -c . || true) headline(s))"
