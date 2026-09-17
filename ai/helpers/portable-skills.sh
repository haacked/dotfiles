#!/usr/bin/env bash
# Which skills must run from a copied skill folder, and the helpers each carries
# to make that true.
#
# A cloud agent run uploads one skill directory and unpacks it into a sandbox
# with no clone of this repo. A skill listed here therefore vendors every helper
# it calls. Its SKILL.md names no path outside the folder. sync-portable-skills.sh
# writes the copies from the sources below. CI rejects a stale or missing one.
#
# Usage: source portable-skills.sh, then:
#   portable_skill_names              -> one skill name per line
#   portable_skill_helpers <skill>    -> "<source> <destination>" per line
#   portable_skill_own_files <skill>  -> one hand-maintained path per line

# skill:source:destination. `source` is relative to the repo root. `destination` is
# relative to the skill's scripts/ directory.
#
# git-pr appears without a sourcing line because lib/github.sh execs ../git-pr as
# a command. lib/copilot.sh sources its sibling lib/github.sh, so the two travel
# together. check-pending-reviews.sh reads helpers/pending-reviews.jq at runtime.
PORTABLE_SKILL_TABLE='wait-for-pr-reviews:bin/detect-pr.sh:detect-pr.sh
wait-for-pr-reviews:bin/git-pr:git-pr
wait-for-pr-reviews:bin/lib/logging.sh:lib/logging.sh
wait-for-pr-reviews:bin/lib/github.sh:lib/github.sh
address-pr-reviews:bin/detect-pr.sh:detect-pr.sh
address-pr-reviews:bin/git-pr:git-pr
address-pr-reviews:bin/gh-resolve-threads:gh-resolve-threads
address-pr-reviews:bin/lib/logging.sh:lib/logging.sh
address-pr-reviews:bin/lib/github.sh:lib/github.sh
address-pr-reviews:bin/lib/copilot.sh:lib/copilot.sh
address-pr-reviews:bin/lib/fs.sh:lib/fs.sh
address-pr-reviews:ai/skills/wait-for-pr-reviews/scripts/check-pending-reviews.sh:check-pending-reviews.sh
address-pr-reviews:ai/skills/wait-for-pr-reviews/scripts/helpers/pending-reviews.jq:helpers/pending-reviews.jq'

# skill:path. Every file under a portable skill's scripts/ directory that the table
# above does not write. Copies and hand-maintained scripts sit in the same folder and
# look alike, so sync-portable-skills.sh --check needs both lists to tell a file whose
# table row was renamed from a script that was always meant to be there.
PORTABLE_SKILL_OWN_FILES='wait-for-pr-reviews:check-pending-reviews.sh
wait-for-pr-reviews:helpers/pending-reviews.jq
wait-for-pr-reviews:tests/test-pending-reviews.sh
wait-for-pr-reviews:tests/test-portable-skill.sh
wait-for-pr-reviews:wait-for-pending-reviews.sh
address-pr-reviews:fetch-unaddressed-comments.sh
address-pr-reviews:record-dismissed-comment.sh
address-pr-reviews:record-step.sh
address-pr-reviews:tests/test-portable-skill.sh'

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
