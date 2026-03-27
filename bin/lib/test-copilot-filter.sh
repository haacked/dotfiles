#!/bin/bash
# Tests for the jq filtering logic used by minimize_copilot_reviews in copilot.sh.
#
# Usage: test-copilot-filter.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# The jq filter extracted from minimize_copilot_reviews (copilot.sh:175-176)
filter_reviews() {
    local exclude_id="$1"
    local reviews_json="$2"
    echo "$reviews_json" | jq --arg exclude "$exclude_id" \
        '[.[] | select(.body != null and .body != "" and (.id | tostring) != $exclude)]'
}

# ── Test data ─────────────────────────────────────────────────────────────

reviews='[
  {"id": 100, "node_id": "PRR_a", "body": "Copilot reviewed 3 of 5 files"},
  {"id": 200, "node_id": "PRR_b", "body": "Copilot reviewed 5 of 5 files"},
  {"id": 300, "node_id": "PRR_c", "body": ""},
  {"id": 400, "node_id": "PRR_d", "body": null},
  {"id": 500, "node_id": "PRR_e", "body": "Copilot reviewed 2 of 5 files"}
]'

# ── Test: excludes specified ID and filters empty/null bodies ─────────────

result=$(filter_reviews "200" "$reviews")
count=$(echo "$result" | jq 'length')
assert "excludes ID 200 and empty bodies, keeps 2" test "$count" -eq 2
ids=$(echo "$result" | jq -c '[.[].id] | sort')
assert "keeps IDs 100 and 500" test "$ids" = "[100,500]"

# ── Test: excludes nothing when ID doesn't match ─────────────────────────

result=$(filter_reviews "999" "$reviews")
count=$(echo "$result" | jq 'length')
assert "keeps all 3 non-empty reviews when exclude misses" test "$count" -eq 3

# ── Test: empty exclude string keeps all non-empty reviews ────────────────

result=$(filter_reviews "" "$reviews")
count=$(echo "$result" | jq 'length')
assert "empty exclude keeps all 3 non-empty reviews" test "$count" -eq 3

# ── Test: empty input array ───────────────────────────────────────────────

result=$(filter_reviews "100" "[]")
count=$(echo "$result" | jq 'length')
assert "empty input returns empty output" test "$count" -eq 0

# ── Test: all reviews excluded or empty ───────────────────────────────────

sparse='[{"id": 100, "node_id": "PRR_a", "body": "only one"}]'
result=$(filter_reviews "100" "$sparse")
count=$(echo "$result" | jq 'length')
assert "single review excluded returns empty" test "$count" -eq 0

# ── Test: numeric ID comparison works via tostring ────────────────────────
# The exclude arg is always a string; .id is numeric in the JSON.
# The filter uses (.id | tostring) to bridge the types.

result=$(filter_reviews "100" "$reviews")
first_id=$(echo "$result" | jq '.[0].id')
assert "numeric-to-string comparison excludes ID 100" test "$first_id" -eq 200

# ── Test: node_id values survive filtering for mutation targets ───────────

result=$(filter_reviews "100" "$reviews")
node_ids=$(echo "$result" | jq -c '[.[].node_id] | sort')
assert "filtered results preserve correct node_ids" test "$node_ids" = '["PRR_b","PRR_e"]'

# ── Results ───────────────────────────────────────────────────────────────

print_results
