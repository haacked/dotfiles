#!/usr/bin/env bash
# Tests for vault-next-source.sh (ledger matching) and vault-lint-links.sh
# (link extraction, orphan/duplicate detection, ledger-link exclusion).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXT="${SCRIPT_DIR}/../vault-next-source.sh"
LINT="${SCRIPT_DIR}/../vault-lint-links.sh"

passes=0
failures=0

check() { # desc actual expected
    if [[ "$2" == "$3" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $1"
        echo "  expected [$3], got [$2]"
        failures=$((failures + 1))
    fi
}

V=$(mktemp -d)
trap 'rm -rf "$V"' EXIT

# --- vault-next-source.sh: ledger matching ---
mkdir -p "$V/standup" "$V/daily"
printf 'x\n' > "$V/standup/2026-08-10.md"
printf 'y\n' > "$V/standup/2026-08-10-part2.md"
printf 'z\n' > "$V/daily/2026-08-11.md"
printf 'n\n' > "$V/standup/2026-08-12.md"
printf 'l\n' > "$V/standup/2026-08-13.md"
cat > "$V/log.md" <<'EOF'
# Operations Log

Preamble mentioning `standup/2026-08-13.md` before any entry heading.

## [2026-08-11] ingest | recap

Source: `standup/2026-08-10-part2.md`. Updated: [[a]].

## [2026-08-12] note | restructure

Moved things around; the new raw file is `standup/2026-08-12.md`.

## [2026-08-13] lint | health check

Checked everything, including `standup/2026-08-10.md`.
EOF

check "prefix sibling stays in backlog" "$(VAULT="$V" "$NEXT" all 2>/dev/null | grep -cF 'standup/2026-08-10.md')" "1"
check "ingested source marked processed" "$(VAULT="$V" "$NEXT" all 2>/dev/null | grep -cF 'standup/2026-08-10-part2.md' || true)" "0"
check "path named in a note entry stays in backlog" "$(VAULT="$V" "$NEXT" all 2>/dev/null | grep -cF 'standup/2026-08-12.md')" "1"
check "path named in the preamble stays in backlog" "$(VAULT="$V" "$NEXT" all 2>/dev/null | grep -cF 'standup/2026-08-13.md')" "1"
check "backlog count" "$(VAULT="$V" "$NEXT" all 2>/dev/null | grep -c .)" "4"
check "bad count rejected" "$(VAULT="$V" "$NEXT" banana 2>&1 | grep -c 'Error' || true)" "1"

# --- vault-lint-links.sh: extraction and orphan exclusions ---
mkdir -p "$V/reference"
cat > "$V/reference/page-a.md" <<'EOF'
Links to [[page-b]] (exists) and [[ghost-page]] (dead).

```bash
if [[ -n "$x" ]]; then :; fi
```

~~~bash
[[tilde-fenced]] not a link
~~~

Inline `[[not-a-link]]` here.
EOF
printf 'back to [[page-a]]\n' > "$V/reference/page-b.md"

# Duplicate-name fixtures: exact dup across wiki dirs, a case/space vs kebab
# variant, and dups in raw/working-doc areas that must not be reported.
# Created after the vault-next-source checks so the raw fixtures don't
# perturb the backlog counts above.
mkdir -p "$V/sdks" "$V/repositories/posthog" "$V/ops-reports/2026-08-01" "$V/ops-reports/2026-08-02" "$V/repositories/a/plans" "$V/repositories/b/plans" "$V/sprint-planning" "$V/quarterly-planning"
printf 'topic\n' > "$V/reference/dup-topic.md"
printf 'topic again\n' > "$V/sdks/dup-topic.md"
printf 'cache notes\n' > "$V/reference/Widget Cache.md"
printf 'cache notes again\n' > "$V/repositories/posthog/widget-cache.md"
printf 'report\n' > "$V/ops-reports/2026-08-01/svc.md"
printf 'report\n' > "$V/ops-reports/2026-08-02/svc.md"
printf 'plan\n' > "$V/repositories/a/plans/plan.md"
printf 'plan\n' > "$V/repositories/b/plans/plan.md"
printf 'sp\n' > "$V/sprint-planning/cadence.md"
printf 'qp\n' > "$V/quarterly-planning/cadence.md"
# Names made only of separators normalize to an empty key and must not
# cluster (or collide with the grouping awk's empty prev sentinel).
printf 'dash\n' > "$V/reference/-.md"
printf 'underscore\n' > "$V/sdks/_.md"
# A page whose only mention is a ledger entry: log.md links must not count
# as inbound links (or as dead-link sources — see [[a]] in the ledger above).
printf 'only the ledger names me\n' > "$V/reference/ledger-only.md"
printf 'Pages: [[ledger-only]]\n' >> "$V/log.md"

out=$("$LINT" "$V")
dup_section=$(sed -n '/== Duplicate wiki page names ==/,$p' <<< "$out")
check "reports the real dead link" "$(grep -c 'ghost-page' <<< "$out")" "1"
check "backtick-fenced [[ ]] excluded" "$(grep -c '\-n' <<< "$out" || true)" "0"
check "tilde-fenced [[ ]] excluded" "$(grep -c 'tilde-fenced' <<< "$out" || true)" "0"
check "inline-code [[ ]] excluded" "$(grep -c 'not-a-link' <<< "$out" || true)" "0"
check "raw-area file not an orphan" "$(grep -c 'standup/2026-08-10' <<< "$out" || true)" "0"
check "exact dup reported" "$(grep -c 'dup-topic.md' <<< "$dup_section")" "2"
check "name-variant dup reported" "$(grep -c 'Widget Cache.md\|widget-cache.md' <<< "$dup_section")" "2"
check "raw-area dups excluded" "$(grep -c 'ops-reports' <<< "$dup_section" || true)" "0"
check "plans dups excluded" "$(grep -c '/plans/' <<< "$dup_section" || true)" "0"
check "planning cadence dirs excluded" "$(grep -c 'sprint-planning\|quarterly-planning' <<< "$out" || true)" "0"
check "empty-key names don't cluster" "$(grep -c -- '-\.md' <<< "$dup_section" || true)" "0"
check "unique page not a dup" "$(grep -c 'page-b' <<< "$dup_section" || true)" "0"
check "log.md links are not dead-link sources" "$(grep -c '\[\[a\]\]' <<< "$out" || true)" "0"
check "ledger-only page is an orphan" "$(grep -c 'ledger-only' <<< "$out")" "1"

# --- vault-lint-links.sh: --skip-raw-sources ---
# A dead link in a raw source can only be fixed by restoring its target, since
# raw files are never edited. The default report keeps those visible; the
# scheduled check (bin/vault-ingest-run) skips them to stay quiet by default.
printf 'points at [[vanished-page]]\n' >> "$V/standup/2026-08-13.md"

raw_out=$("$LINT" "$V")
skip_out=$("$LINT" --skip-raw-sources "$V")
check "raw dead link reported by default" "$(grep -c 'vanished-page' <<< "$raw_out")" "1"
check "raw dead link skipped with flag" "$(grep -c 'vanished-page' <<< "$skip_out" || true)" "0"
check "wiki dead link survives the flag" "$(grep -c 'ghost-page' <<< "$skip_out")" "1"
check "flag keeps the orphan check intact" "$(grep -c 'ledger-only' <<< "$skip_out")" "1"
check "mistyped flag is rejected" "$("$LINT" --skip-raw-source "$V" 2>&1 >/dev/null | grep -c 'Unknown option')" "1"
check "mistyped flag exits 64" "$("$LINT" --skip-raw-source "$V" >/dev/null 2>&1; echo $?)" "64"

# The scheduled check in bin/vault-ingest-run parses this section by header and
# line shape, so both are part of the interface, not incidental formatting.
check "dead-link section header is stable" "$(grep -c '^== Dead wikilinks ==' <<< "$skip_out")" "1"
dead_lines=$(awk '/^== Dead wikilinks ==/ { inside = 1; next } /^== / { inside = 0 } inside && NF && $0 != "(none)"' <<< "$skip_out")
check "dead-link lines are 'path -> [[target]]'" "$(grep -cv '^.* -> \[\[.*\]\]$' <<< "$dead_lines" || true)" "0"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
