#!/usr/bin/env bash
# Report dead [[wikilinks]], orphan wiki pages (no inbound wikilinks), and
# duplicate wiki page names (consolidation candidates).
#
# Usage: vault-lint-links.sh [vault-dir]
#
# Report-only; exits 0 except when the vault dir can't be entered (no -e: a
# file with zero wikilinks makes the extraction pipeline "fail", which must
# not kill the report). Obsidian
# resolves [[Name]] by basename anywhere in the vault and [[dir/Name]] by
# path, so a link is dead only when neither resolves. Raw areas, plans, dated
# planning dirs, and structural files are excluded from the orphan and
# duplicate checks (they aren't expected to have inbound links, and dated
# duplicates there are by design). log.md is excluded as a link source: ledger
# mentions are
# point-in-time history, not navigation — they must not rescue a page from
# orphan status, and past entries are never edited, so a deleted page would
# otherwise be a dead link forever. Raw sources stay link sources on purpose:
# their links to consolidated-away pages surface as dead links, keeping those
# permanent stragglers visible.

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
    [[ "$f" == "log.md" ]] && continue
    # shellcheck disable=SC2016  # backticks in the sed pattern are literal, not expansions
    awk '/^[[:space:]]*(```|~~~)/ { infence = !infence; next } !infence { print }' "$f" 2>/dev/null | sed 's/`[^`]*`//g' | grep -o '\[\[[^]]*\]\]' | sed -e 's/^\[\[//' -e 's/\]\]$//' -e 's/|.*//' -e 's/#.*//' | while IFS= read -r target; do
        [[ -n "$target" ]] && printf '%s\t%s\n' "$f" "$target" >> "$tmpdir/links"
    done
done < "$tmpdir/files"

echo "== Dead wikilinks =="
dead=0
while IFS=$'\t' read -r f target; do
    base="${target##*/}"
    if ! grep -qxF -- "${target}.md" "$tmpdir/files" && ! grep -qxF -- "${base}.md" "$tmpdir/files" && ! grep -qF -- "/${base}.md" "$tmpdir/files"; then
        printf '%s -> [[%s]]\n' "$f" "$target"
        dead=$((dead + 1))
    fi
done < "$tmpdir/links"
[[ "$dead" -eq 0 ]] && echo "(none)"

# Wiki-layer pages only, per the layer schema in the vault's CLAUDE.md (raw
# areas stay in sync with vault-next-source.sh's find list).
while IFS= read -r f; do
    case "$f" in
        standup/*|ops-reports/*|daily/*|support/*|2[0-9][0-9][0-9]/*|*/plans/*|*/archive/*|sprint-planning/*|quarterly-planning/*|Followups.md|log.md|CLAUDE.md|Home.md) continue ;;
    esac
    printf '%s\n' "$f"
done < "$tmpdir/files" > "$tmpdir/wiki"

echo ""
echo "== Orphan wiki pages (no inbound wikilinks) =="
orphans=0
while IFS= read -r f; do
    base="${f##*/}"
    base="${base%.md}"
    # Pure string suffix check — a regex here would let metacharacters in page
    # names (dots, parens) misclassify orphans.
    if ! awk -F'\t' -v b="$base" '$2 == b || substr($2, length($2) - length(b)) == "/" b { found = 1; exit } END { exit !found }' "$tmpdir/links"; then
        orphans=$((orphans + 1))
        [[ "$orphans" -le 20 ]] && printf '%s\n' "$f"
    fi
done < "$tmpdir/wiki"
if [[ "$orphans" -eq 0 ]]; then
    echo "(none)"
elif [[ "$orphans" -gt 20 ]]; then
    echo "(+$((orphans - 20)) more — ${orphans} orphans total)"
fi

echo ""
echo "== Duplicate wiki page names =="
# Same-basename wiki pages resolve [[Name]] ambiguously; case/space/hyphen/
# underscore variants usually mean one topic split across pages. Both are
# consolidation candidates (/vault consolidate). Clusters print one path per
# line, blank-line separated. Names that normalize to nothing are skipped, and
# LC_ALL=C keeps equal keys adjacent regardless of locale.
awk -F/ '{ base = $NF; sub(/\.md$/, "", base); key = tolower(base); gsub(/[ _-]/, "", key); if (key != "") printf "%s\t%s\n", key, $0 }' "$tmpdir/wiki" | LC_ALL=C sort > "$tmpdir/names"
awk -F'\t' '
    NR == FNR { n[$1]++; next }
    n[$1] > 1 { if ($1 != prev) { if (found++) print ""; prev = $1 } print "  " $2 }
    END { if (!found) print "(none)" }
' "$tmpdir/names" "$tmpdir/names"
