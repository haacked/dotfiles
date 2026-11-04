# pending-reviews.jq - Pure verdict for which reviewers are still mid-review on a PR.
#
# Two kinds of in-flight review are detected:
#
#   comment             ReviewHog: a person's `@posthog review` comment (optionally
#                       with `--deep`) starts a round. The comment stays on the PR
#                       after the round completes, so its presence alone is not
#                       "pending". The verdict pairs the latest one with the absence
#                       of a marked completion since it was posted.
#   requested_reviewer  Copilot, Greptile, and any other bot among the PR's
#                       requested reviewers. GitHub clears a user entry when its
#                       review is submitted, so presence alone IS "pending". Teams
#                       are excluded upstream: a team request lingers until a human
#                       member reviews, which a bot's review never satisfies.
#
# ReviewHog posts as posthog[bot], not from a "reviewhog" login. Its reviews and
# comments carry HTML markers (`<!-- reviewhog:published:…:<mode> -->` on the review,
# `<!-- reviewhog:status:… -->` on a status comment posted as a placeholder and
# edited in place as the round progresses and when it finishes). A marked review
# submitted after the trigger comment completes the round. A marked status comment
# also completes the round when updated after the trigger and its own creation,
# unless it still contains the word "reviewing". Every progress edit has the
# heading "PostHog Review · Deep · reviewing", and the finished one says
# "reviewed". A comment whose updated_at equals its created_at is the fresh
# placeholder, i.e. the round just started.
#
# ReviewHog also runs a Standard round on its own when a PR opens. That round's
# review carries the `:flash` mode, and a Deep round's review carries `:full`. A
# Standard review can land after a `--deep` trigger, so a `--deep` trigger counts
# only a `:full` review as its completion.
#
# A trigger at a head that already has a published review in that mode starts no
# run, so no review lands after it. A `published` review whose commit is the
# current head therefore completes the round whenever it was submitted. A clean
# Standard round's `clean-reply` review does not count this way, because ReviewHog
# runs a requested round again at that head and can publish findings after it.
#
# Only posthog[bot]'s markers count: a different bot quoting a ReviewHog report (or
# echoing injected text) must not read as a completion, or the wait would end
# while the real round is still running. The `review-?hog` login pattern is a
# forward hedge for ReviewHog ever gaining its own app identity. A bot's comment
# never counts as a trigger, so ReviewHog's own replies cannot start a wait.
#
# Timestamps are the API's UTC `Z` strings, so ordering is a string compare.
#
# Input (stdin), one object (fields pre-projected by check-pending-reviews.sh):
#   { head_sha: <the PR's head commit>,
#     timeline: [{event: "review_requested", reviewer, created_at}],
#     reviews: [{login, type, body, commit_id, submitted_at}],
#     comments: [{login, type, body, created_at, updated_at}],
#     requested_users: [{login, type}] }   # type: GraphQL __typename
# Output: { pending: [{reviewer, signal: "comment"|"requested_reviewer", since}],
#           warnings: [<string>] }
#   since: when the trigger comment was posted (comment) or the review was
#   requested (requested_reviewer); null when no timeline event dates it.

def REVIEWHOG_MARKER: "<!-- reviewhog:";
def REVIEWHOG_POSTING_LOGIN: "posthog[bot]";

# Mirrors COPILOT_LOGIN_JQ in the sibling lib/copilot.sh, which is bin/lib/copilot.sh
# in the repo and scripts/lib/copilot.sh in a portable skill (a `jq -f` program cannot read a
# bash constant) - keep the two in sync. Exact match, not substring, so a human
# handle that merely contains "copilot" stays a human.
def is_copilot_login:
  ascii_downcase
  | . == "copilot" or . == "copilot-pull-request-reviewer" or . == "copilot-pull-request-reviewer[bot]";

# GitHub records Copilot's `review_requested` timeline event under the login
# "Copilot" while the reviewRequests node carries "copilot-pull-request-reviewer",
# so dating the request needs an alias-aware match, not string equality.
def same_reviewer($a; $b):
  ((($a // "") | ascii_downcase) == (($b // "") | ascii_downcase))
  or ((($a // "") | is_copilot_login) and (($b // "") | is_copilot_login));

def is_reviewhog_login: ascii_downcase | test("review-?hog");
def is_reviewhog_actor:
  (.type == "Bot")
  and (((.login // "") | is_reviewhog_login)
       or ((((.login // "") | ascii_downcase) == REVIEWHOG_POSTING_LOGIN)
           and ((.body // "") | contains(REVIEWHOG_MARKER))));
def is_reviewhog_in_progress:
  (.body // "") | ascii_downcase | test("\\breviewing\\b");
def is_reviewhog_trigger:
  (.type != "Bot") and ((.body // "") | ascii_downcase | test("^\\s*@posthog\\s+review(\\s|$)"));
def is_deep_trigger: (.body // "") | ascii_downcase | test("\\s--deep(\\s|$)");
def is_deep_review: (.body // "") | test("<!-- reviewhog:published:[^>]*:full -->");
def is_published_review: (.body // "") | contains("<!-- reviewhog:published:");

. as $in
| ($in.head_sha // "") as $head
| ([ $in.comments[]? | select(is_reviewhog_trigger and .created_at != null) ]
   | max_by(.created_at)) as $trigger
| (if $trigger != null then
     $trigger.created_at as $since
     | ($trigger | is_deep_trigger) as $deep
     | ( ([ $in.reviews[]?
            | select(is_reviewhog_actor
                     and (($deep | not) or is_deep_review)
                     and ((.submitted_at != null and .submitted_at > $since)
                          or ($head != "" and .commit_id == $head and is_published_review))) ]
          | length > 0)
         or
         ([ $in.comments[]?
            | select(is_reviewhog_actor and .updated_at != null
                     and .updated_at > $since and .updated_at > .created_at
                     and (is_reviewhog_in_progress | not)) ]
          | length > 0) ) as $completed
     | if $completed then [] else [{reviewer: "reviewhog", signal: "comment", since: $since}] end
   else [] end) as $reviewhog_pending
# .type carries GraphQL's __typename ("Bot"/"User"), matching copilot.sh's is_bot
# check for the same "Bot, or Copilot's odd login" test.
| (($in.requested_users // [])
   | map(select(.type == "Bot" or ((.login // "") | is_copilot_login)))
   | map(. as $bot
     | { reviewer: $bot.login,
         signal: "requested_reviewer",
         since: ([ $in.timeline[]?
                   | select(.event == "review_requested"
                            and same_reviewer(.reviewer; $bot.login))
                   | .created_at ] | max) })) as $requested_pending
| {pending: ($reviewhog_pending + $requested_pending), warnings: []}
