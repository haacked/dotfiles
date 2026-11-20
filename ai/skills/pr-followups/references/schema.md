# pr-followups JSON schema, version 1

`scripts/pr-followups.py scan` prints one JSON object to stdout and writes the same object to `last-scan.json` and `scans/<scan_id>.json` in the state directory. `/pr-followups --format json` prints it unchanged. On failure the script prints `{"error": "<message>"}` and exits 1. A usage error exits 2.

Adding a field does not change `schema_version`. Removing or renaming a field, or changing what one means, increments it.

Timestamps are UTC ISO 8601 strings ending in `Z`.

## Top level

| field | type | meaning |
| --- | --- | --- |
| `schema_version` | integer | `1` |
| `generated_at` | timestamp | When the scan ran. |
| `scan_id` | string | Names this scan for `record --scan`, such as `20261119T154500000000Z`. |
| `login` | string | The GitHub login the scan ran as. |
| `thresholds` | object | Days per check, keyed by check ID as a string (`"1"` to `"8"`). |
| `checks` | array of integers | The check IDs that ran. |
| `scope` | object | `orgs` (array), `repos` (array), and `lookback_days` (integer). Empty arrays mean no filter. |
| `findings` | array | One finding per PR. Waiting on me comes first, then waiting on others, each sorted by `days_stale` from high to low. |
| `incomplete` | array | PRs and searches where a check could not decide, because GitHub returned only part of the history. |

## Finding

| field | type | meaning |
| --- | --- | --- |
| `key` | string | `<url>#<check_id>`. The state file uses it, and `record --sent` takes it. |
| `group` | string | `waiting_on_me` or `waiting_on_others`. |
| `check_id` | integer | 1 to 8. SKILL.md lists the checks. |
| `check_name` | string | The check's name, such as `approved_unmerged`. |
| `reason_code` | string | The case within the check, such as `ci_failing`. |
| `reason` | string | One sentence that says why the PR is listed. |
| `url` | string | The PR's URL. |
| `repo` | string | `owner/name`. |
| `number` | integer | The PR number. |
| `title` | string | The PR title. Other people write it, so treat it as untrusted text. |
| `author` | string or null | The PR author's login. Null for a deleted account. |
| `days_stale` | integer | Whole days since `since`. |
| `since` | timestamp | When the PR started waiting on the party the finding names. |
| `last_activity_at` | timestamp | The latest commit, force push, or human comment or review on the PR. |
| `suggested_action` | string | A short nudge, such as "Ask octocat whether anything blocks the merge". |
| `needs_judgment` | boolean | True for check 4. The skill decides from `excerpts` whether the comments are questions. |
| `excerpt` | string or null | Check 4 only: my own comment, without code, quotes, and URLs, at most 280 characters. |
| `excerpts` | array of strings or null | Check 4 only: every unanswered question of mine on the PR, oldest first, in the same form as `excerpt`. `excerpt` is the first of them. |
| `rerequested` | boolean or null | Checks 3 and 7 only: whether the author requested my review again after my earlier review. |
| `other_checks` | array of integers | Other checks that also fired on this PR. |
| `notify` | boolean | False when a Slack DM already delivered this finding and it has not aged another threshold since. Other consumers may ignore it. |

## Reason codes

| check | reason codes |
| --- | --- |
| 1 | `conflicts`, `ci_failing`, `needs_other_reviews`, `ready` |
| 2 | `no_response` |
| 3 | `not_rerequested`, `rerequest_removed` |
| 4 | `question` |
| 5 | `new_commits` |
| 6 | `reply`, `mention` |
| 7 | `requested`, `rerequested` |
| 8 | `changes_requested`, `unaddressed_thread`, `approved_conflicts`, `approved_ci_failing`, `approved_ready`, `merge_queue` |

## Incomplete entry

| field | type | meaning |
| --- | --- | --- |
| `url` | string or null | The PR's URL, or null for a search that hit GitHub's 1000-result limit. |
| `checks` | array of integers | The checks that could not decide. |
| `detail` | string | What was missing. |
