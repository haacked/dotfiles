# approval-safety.jq - Pure verdict for auto-approving a re-gated fork PR.
#
# Decides whether the gated workflows on an outside-contributor PR can be
# auto-approved because the only change since the last approval was a sync from
# the base branch (a merge or rebase of master), with no new contributor code.
#
# Why the blob-sha signature of a three-dot compare is a sound safety check:
# `compare/BASE...HEAD` diffs from merge-base(BASE, HEAD) to HEAD. The merge base
# is always an ancestor of BASE (trusted master), so its tree is entirely
# trusted. Any contributor content that is NOT already in master therefore MUST
# appear in the three-dot diff. The `sha` field is the whole-file (blob) content
# hash, so any change to a touched file's content flips the signature. An
# attacker cannot hide content in the merge base, because the merge base is an
# ancestor of master and a contributor cannot write to master. So: identical
# signatures before and after => the contributor added nothing new.
#
# Fails closed (safe:false) on every uncertainty. False negatives are harmless
# (a human still approves); a false positive runs unreviewed code, so it must
# never happen.
#
# Input (stdin), one object:
#   { last_approved_sha, current_head_sha, gated_runs:[{event,...}],
#     compare_then:<compare API JSON>, compare_now:<compare API JSON> }
# Output: { safe, reason, last_approved_sha, current_head_sha }

# Content signature of a compare response: every touched file by name, change
# type, blob sha, and rename source. .github/ is deliberately NOT excluded - a
# contributor-modified workflow file IS contributor content and must fail closed.
def sig(c): [ (c.files // [])[] | {filename, status, sha, previous_filename} ]
            | sort_by(.filename);

. as $in
| (($in.gated_runs // [])) as $runs
| (($in.compare_then.files // []) | length) as $n_then
| (($in.compare_now.files // []) | length) as $n_now
| (
    if (($in.last_approved_sha // "") == "") then
      {safe: false, reason: "no prior approved run found for this PR head branch"}
    elif (($runs | length) == 0) then
      {safe: false, reason: "no gated runs awaiting approval"}
    elif ($runs | any(.event == "pull_request_target")) then
      {safe: false, reason: "a gated run uses pull_request_target; refusing to auto-approve"}
    elif ($in.last_approved_sha == $in.current_head_sha) then
      {safe: true, reason: "current head identical to last approved sha"}
    elif ($n_then >= 300 or $n_now >= 300) then
      {safe: false, reason: "compare diff may be truncated (>=300 files); cannot verify contributor patch"}
    elif (sig($in.compare_then) == sig($in.compare_now)) then
      {safe: true, reason: "contributor patch unchanged since last approval (base-branch sync only)"}
    else
      {safe: false, reason: "contributor patch changed since last approval"}
    end
  )
| . + {last_approved_sha: ($in.last_approved_sha // null),
       current_head_sha: ($in.current_head_sha // null)}
