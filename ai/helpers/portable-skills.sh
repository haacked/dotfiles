#!/usr/bin/env bash
# Which skills must run from a copied skill folder, and the helpers each carries
# to make that true.
#
# A cloud agent run uploads one skill directory and unpacks it into a sandbox
# with no clone of this repo. A skill listed here therefore vendors every helper
# it calls and every skill it delegates a pass to. Its SKILL.md names no path
# outside the folder. sync-portable-skills.sh writes the copies from the sources
# below. CI rejects a stale or missing one.
#
# Usage: source portable-skills.sh, then:
#   portable_skill_names              -> one skill name per line
#   portable_skill_helpers <skill>    -> "<source> <destination>" per line
#   portable_skill_own_files <skill>  -> one hand-maintained path per line

# skill:source:destination. Both are relative, `source` to the repo root and
# `destination` to the skill's own directory.
#
# git-pr appears without a sourcing line because lib/github.sh execs ../git-pr as
# a command. lib/copilot.sh sources its sibling lib/github.sh, so the two travel
# together. check-pending-reviews.sh reads helpers/pending-reviews.jq at runtime.
#
# A references/<skill>/ copy keeps the source skill's own folder shape, so the
# relative paths written inside its SKILL.md resolve against the copy.
PORTABLE_SKILL_TABLE='wait-for-pr-reviews:bin/detect-pr.sh:scripts/detect-pr.sh
wait-for-pr-reviews:bin/git-pr:scripts/git-pr
wait-for-pr-reviews:bin/lib/logging.sh:scripts/lib/logging.sh
wait-for-pr-reviews:bin/lib/github.sh:scripts/lib/github.sh
address-pr-reviews:bin/detect-pr.sh:scripts/detect-pr.sh
address-pr-reviews:bin/git-pr:scripts/git-pr
address-pr-reviews:bin/gh-resolve-threads:scripts/gh-resolve-threads
address-pr-reviews:bin/lib/logging.sh:scripts/lib/logging.sh
address-pr-reviews:bin/lib/github.sh:scripts/lib/github.sh
address-pr-reviews:bin/lib/copilot.sh:scripts/lib/copilot.sh
address-pr-reviews:bin/lib/fs.sh:scripts/lib/fs.sh
address-pr-reviews:ai/skills/wait-for-pr-reviews/scripts/check-pending-reviews.sh:scripts/check-pending-reviews.sh
address-pr-reviews:ai/skills/wait-for-pr-reviews/scripts/helpers/pending-reviews.jq:scripts/helpers/pending-reviews.jq
address-pr-reviews:ai/skills/comment-cleanup/SKILL.md:references/comment-cleanup/SKILL.md
address-pr-reviews:ai/skills/plain-writing/SKILL.md:references/plain-writing/SKILL.md
address-pr-reviews:ai/skills/plain-writing/references/strict.md:references/plain-writing/references/strict.md
address-pr-reviews:ai/skills/plain-writing/references/voice-match.md:references/plain-writing/references/voice-match.md
address-pr-reviews:ai/skills/plain-writing/scripts/plain-writing-lint.py:references/plain-writing/scripts/plain-writing-lint.py'

# skill:path, each path relative to the skill's own directory. Every file in a portable
# skill except SKILL.md and the copies the table above writes. Copies and hand-maintained
# scripts sit in the same folder and look alike, so sync-portable-skills.sh --check needs
# both lists to tell a file whose table row was renamed from one that was always meant to
# be there.
PORTABLE_SKILL_OWN_FILES='wait-for-pr-reviews:scripts/check-pending-reviews.sh
wait-for-pr-reviews:scripts/helpers/pending-reviews.jq
wait-for-pr-reviews:scripts/tests/test-pending-reviews.sh
wait-for-pr-reviews:scripts/tests/test-portable-skill.sh
wait-for-pr-reviews:scripts/wait-for-pending-reviews.sh
address-pr-reviews:scripts/fetch-unaddressed-comments.sh
address-pr-reviews:scripts/record-dismissed-comment.sh
address-pr-reviews:scripts/record-step.sh
address-pr-reviews:scripts/tests/test-portable-skill.sh'

portable_skill_names() {
    cut -d: -f1 <<< "$PORTABLE_SKILL_TABLE" | sort -u
}

portable_skill_helpers() { # skill
    while IFS=: read -r skill source destination; do
        if [ "$skill" = "$1" ]; then
            printf '%s %s\n' "$source" "$destination"
        fi
    done <<< "$PORTABLE_SKILL_TABLE"
}

portable_skill_own_files() { # skill
    while IFS=: read -r skill path; do
        if [ "$skill" = "$1" ]; then
            printf '%s\n' "$path"
        fi
    done <<< "$PORTABLE_SKILL_OWN_FILES"
}
