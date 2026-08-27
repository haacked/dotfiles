#!/bin/sh

# Shared parser for the per-platform excluded-skills lists.
#
# Both installers and the skill tests read the lists through this one function. A
# looser matcher in any one of them would call a skill excluded that the installer
# still ships, and the mismatch surfaces as an unrelated assertion about a missing
# symlink.

# is_excluded_skill SKILL_NAME EXCLUSIONS_FILE
#
# Succeeds when SKILL_NAME occupies a whole line of EXCLUSIONS_FILE. Blank lines and
# lines whose first non-space character is `#` are skipped. A file that does not
# exist excludes nothing.
is_excluded_skill() {
	[ -f "$2" ] || return 1
	grep -Ev '^[[:space:]]*(#|$)' "$2" | grep -Fxq "$1"
}
