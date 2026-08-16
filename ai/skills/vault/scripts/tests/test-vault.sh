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

out=$("$LINT" "$V")
check "reports the real dead link" "$(grep -c 'ghost-page' <<< "$out")" "1"
check "backtick-fenced [[ ]] excluded" "$(grep -c '\-n' <<< "$out" || true)" "0"
check "tilde-fenced [[ ]] excluded" "$(grep -c 'tilde-fenced' <<< "$out" || true)" "0"
check "inline-code [[ ]] excluded" "$(grep -c 'not-a-link' <<< "$out" || true)" "0"
check "raw-area file not an orphan" "$(grep -c 'standup/2026-08-10' <<< "$out" || true)" "0"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
