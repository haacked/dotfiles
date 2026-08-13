# pending-reviews.jq - Pure verdict for which reviewers are still mid-review on a PR.
#
# Two kinds of in-flight review are detectable from structure alone:
#
#   label               ReviewHog: the `reviewhog` label marks a queued or running
#                       round. The label can linger after the round completes, so
#                       presence alone is not "pending" - the verdict pairs it with
#                       the absence of a marked completion since it was applied.
#   requested_reviewer  Copilot, Greptile, and any other bot among the PR's
#                       requested reviewers. GitHub clears a user entry when its
#                       review is submitted, so presence alone IS "pending". Teams
#                       are excluded upstream: a team request lingers until a human
#                       member reviews, which a bot's review never satisfies.
#
# ReviewHog posts as posthog[bot], not from a "reviewhog" login. Its reviews and
# comments carry HTML markers (`<!-- reviewhog:published:… -->` on the review,
# `<!-- reviewhog:status:… -->` on a status comment posted as a placeholder and
# edited in place when the round finishes). A completion is therefore: a marked
# review submitted after the label was last applied, or a marked comment updated
# after both the label and its own creation - a comment whose updated_at equals
# its created_at is the fresh placeholder, i.e. the round just started. Only
# posthog[bot]'s markers count: a different bot quoting a ReviewHog report (or
# echoing injected text) must not read as a completion, or the wait would end
# while the real round is still running. The `review-?hog` login pattern is a
# forward hedge for ReviewHog ever gaining its own app identity.
#
# The verdict turns on markers and timestamps, never prose. Timestamps are the
# API's UTC `Z` strings, so ordering is a string compare. A label with no dating
# `labeled` event is reported as a warning, never as pending - the label is known
# to linger, and an undatable one must not cost the caller a wait.
#
# Input (stdin), one object (fields pre-projected by check-pending-reviews.sh):
#   { labels: [<name>],
#     timeline: [{event: "labeled"|"review_requested", label, reviewer, created_at}],
#     reviews: [{login, type, body, submitted_at}],
#     comments: [{login, type, body, created_at, updated_at}],
#     requested_users: [{login, type}] }
# Output: { pending: [{reviewer, signal: "label"|"requested_reviewer", since}],
#           warnings: [<string>] }

def REVIEWHOG_LABEL: "reviewhog";
def REVIEWHOG_MARKER: "<!-- reviewhog:";
def REVIEWHOG_POSTING_LOGIN: "posthog[bot]";

# Mirrors COPILOT_LOGIN_JQ in bin/lib/copilot.sh (a `jq -f` program cannot read a
# bash constant) - keep the two in sync. Exact match, not substring, so a human
# handle that merely contains "copilot" stays a human.
def is_copilot_login:
  ascii_downcase
  | . == "copilot" or . == "copilot-pull-request-reviewer" or . == "copilot-pull-request-reviewer[bot]";

def is_reviewhog_login: ascii_downcase | test("review-?hog");
def is_reviewhog_actor:
  (.type == "Bot")
  and (((.login // "") | is_reviewhog_login)
       or ((((.login // "") | ascii_downcase) == REVIEWHOG_POSTING_LOGIN)
           and ((.body // "") | contains(REVIEWHOG_MARKER))));

. as $in
| (($in.labels // []) | map((. // "") | ascii_downcase) | any(. == REVIEWHOG_LABEL)) as $label_present
| ([ $in.timeline[]?
     | select(.event == "labeled" and ((.label // "") | ascii_downcase) == REVIEWHOG_LABEL)
     | .created_at ] | max) as $label_time
| (if $label_present and $label_time != null then
     ( ([ $in.reviews[]?
          | select(is_reviewhog_actor and .submitted_at != null and .submitted_at > $label_time) ]
        | length > 0)
       or
       ([ $in.comments[]?
          | select(is_reviewhog_actor and .updated_at != null
                   and .updated_at > $label_time and .updated_at > .created_at) ]
        | length > 0) ) as $completed
     | if $completed then [] else [{reviewer: "reviewhog", signal: "label", since: $label_time}] end
   else [] end) as $reviewhog_pending
| (if $label_present and $label_time == null then
     ["reviewhog label present but no labeled timeline event dates it; not treating it as pending"]
   else [] end) as $warnings
# .type is the REST user-object field; this mirrors copilot.sh's is_bot check,
# which reads GraphQL's __typename for the same "Bot, or Copilot's odd login" test.
| (($in.requested_users // [])
   | map(select(.type == "Bot" or ((.login // "") | is_copilot_login)))
   | map(. as $bot
     | { reviewer: $bot.login,
         signal: "requested_reviewer",
         since: ([ $in.timeline[]?
                   | select(.event == "review_requested" and .reviewer == $bot.login)
                   | .created_at ] | max) })) as $requested_pending
| {pending: ($reviewhog_pending + $requested_pending), warnings: $warnings}
