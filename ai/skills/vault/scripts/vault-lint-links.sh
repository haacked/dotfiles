#!/usr/bin/env bash
# Report dead [[wikilinks]] and orphan wiki pages (no inbound wikilinks).
#
# Usage: vault-lint-links.sh [vault-dir]
#
# Report-only; always exits 0 (no -e: a file with zero wikilinks makes the
# extraction pipeline "fail", which must not kill the report). Obsidian
# resolves [[Name]] by basename anywhere in the vault and [[dir/Name]] by
# path, so a link is dead only when neither resolves. Raw areas, plans, and
# structural files are excluded from the orphan check (they aren't expected
# to have inbound links).

set -uo pipefail

VAULT="${1:-$HOME/dev/haacked/notes/PostHog}"
cd "$VAULT" || exit 1

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

find . -type f -name '*.md' -not -path './.obsidian/*' | sed 's|^\./||' > "$tmpdir/files"

# Extract file<TAB>target pairs, stripping |aliases and #headings. Fenced
# code blocks and inline code are excluded — bash [[ conditionals ]] in
# code samples are not wikilinks.
: > "$tmpdir/links"
while IFS= read -r f; do
    # shellcheck disable=SC2016  # backticks in the sed pattern are literal, not expansions
    awk '/^[[:space:]]*```/ { infence = !infence; next } !infence { print }' "$f" 2>/dev/null | sed 's/`[^`]*`//g' | grep -o '\[\[[^]]*\]\]' | sed -e 's/^\[\[//' -e 's/\]\]$//' -e 's/|.*//' -e 's/#.*//' | while IFS= read -r target; do
        [[ -n "$target" ]] && printf '%s\t%s\n' "$f" "$target" >> "$tmpdir/links"
    done
done < "$tmpdir/files"

echo "== Dead wikilinks =="
dead=0
while IFS=$'\t' read -r f target; do
    base="${target##*/}"
    if ! grep -qxF "${target}.md" "$tmpdir/files" && ! grep -qxF "${base}.md" "$tmpdir/files" && ! grep -qF "/${base}.md" "$tmpdir/files"; then
        printf '%s -> [[%s]]\n' "$f" "$target"
        dead=$((dead + 1))
    fi
done < "$tmpdir/links"
[[ "$dead" -eq 0 ]] && echo "(none)"

echo ""
echo "== Orphan wiki pages (no inbound wikilinks) =="
orphans=0
while IFS= read -r f; do
    # Raw areas (keep in sync with vault-next-source.sh's find list) plus
    # working docs and structural files not expected to have inbound links.
    case "$f" in
        standup/*|ops-reports/*|daily/*|support/*|2[0-9][0-9][0-9]/*|*/plans/*|*/archive/*|Followups.md|log.md|CLAUDE.md|Home.md) continue ;;
    esac
    base=$(basename "$f" .md)
    if ! awk -F'\t' -v b="$base" '$2 == b || $2 ~ ("/" b "$") { found = 1; exit } END { exit !found }' "$tmpdir/links"; then
        orphans=$((orphans + 1))
        [[ "$orphans" -le 20 ]] && printf '%s\n' "$f"
    fi
done < "$tmpdir/files"
if [[ "$orphans" -eq 0 ]]; then
    echo "(none)"
elif [[ "$orphans" -gt 20 ]]; then
    echo "(+$((orphans - 20)) more — ${orphans} orphans total)"
fi
