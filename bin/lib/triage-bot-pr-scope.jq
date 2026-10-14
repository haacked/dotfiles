# Picks the Feature Flags PRs out of the bot PR queue for bin/triage-bot-pr-queue.
#
# Input: the `gh pr list` results array.
# $limit: the --limit the search ran with.
# $files: one {number, files} object per queued PR whose file fetch succeeded.
# Output: {fetched, capped, inScope: [{number, title, bot, createdAt, labels,
#   assignees, files, flagsPaths, dirs}], outOfScope, unfetched}
# dirs lists up to five parent directories of flagsPaths, the most-touched
# first. The helper looks up recent committers in them.

include "flags-domain";

INDEX($files[]; .number) as $by_number
| [ .[] | select(unrequested_bot_pr) ] as $queue
| [ $queue[]
    | ($by_number[.number | tostring].files) as $files
    | select($files != null)
    | [.labels[].name] as $labels
    | [$files[] | select(flags_path)] as $flags_paths
    | select(any($labels[]; IN(flags_labels[])) or ($flags_paths | length > 0))
    | {
        number,
        title,
        bot: .author.login,
        createdAt,
        labels: $labels,
        assignees: [.assignees[].login],
        files: $files,
        flagsPaths: $flags_paths,
        dirs: (
          [$flags_paths[] | select(contains("/")) | sub("/[^/]*$"; "")]
          | group_by(.) | sort_by(-length) | map(.[0]) | .[:5]
        )
      }
  ] as $in_scope
| [ $queue[] | select($by_number[.number | tostring] == null) | .number ] as $unfetched
| {
    fetched: length,
    capped: (length >= $limit),
    inScope: ($in_scope | sort_by(.number)),
    outOfScope: (($queue | length) - ($in_scope | length) - ($unfetched | length)),
    unfetched: $unfetched
  }
