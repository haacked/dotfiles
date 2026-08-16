#!/usr/bin/env bash
# Tests for vault-next-source.sh (ledger matching) and vault-lint-links.sh (link extraction).
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
cat > "$V/log.md" <<'EOF'
# Operations Log

## [2026-08-11] ingest | recap

Source: `standup/2026-08-10-part2.md`. Updated: [[a]].
EOF

check "prefix sibling stays in backlog" "$(VAULT="$V" "$NEXT" all 2>/dev/null | grep -cF 'standup/2026-08-10.md')" "1"
check "ingested source marked processed" "$(VAULT="$V" "$NEXT" all 2>/dev/null | grep -cF 'standup/2026-08-10-part2.md' || true)" "0"
check "backlog count" "$(VAULT="$V" "$NEXT" all 2>/dev/null | grep -c .)" "2"
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
mkdir -p "$V/sdks" "$V/repositories/posthog" "$V/ops-reports/2026-08-01" "$V/ops-reports/2026-08-02" "$V/repositories/a/plans" "$V/repositories/b/plans"
printf 'topic\n' > "$V/reference/dup-topic.md"
printf 'topic again\n' > "$V/sdks/dup-topic.md"
printf 'cache notes\n' > "$V/reference/Widget Cache.md"
printf 'cache notes again\n' > "$V/repositories/posthog/widget-cache.md"
printf 'report\n' > "$V/ops-reports/2026-08-01/svc.md"
printf 'report\n' > "$V/ops-reports/2026-08-02/svc.md"
printf 'plan\n' > "$V/repositories/a/plans/plan.md"
printf 'plan\n' > "$V/repositories/b/plans/plan.md"
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
check "exact dup reported" "$(grep -c 'dup-topic.md' <<< "$dup_section" || true)" "2"
check "name-variant dup reported" "$(grep -c 'Widget Cache.md\|widget-cache.md' <<< "$dup_section" || true)" "2"
check "raw-area dups excluded" "$(grep -c 'ops-reports' <<< "$dup_section" || true)" "0"
check "plans dups excluded" "$(grep -c '/plans/' <<< "$dup_section" || true)" "0"
check "unique page not a dup" "$(grep -c 'page-b' <<< "$dup_section" || true)" "0"
check "log.md links are not dead-link sources" "$(grep -c '\[\[a\]\]' <<< "$out" || true)" "0"
check "ledger-only page is an orphan" "$(grep -c 'ledger-only' <<< "$out" || true)" "1"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
