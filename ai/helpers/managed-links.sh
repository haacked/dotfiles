#!/bin/sh

# Symlink helpers shared by the Claude and Codex installers.
#
# Requires `warning` from ai/helpers/output.sh, so source that first.

# install_managed_link SOURCE DESTINATION MANAGED_PREFIX
#
# Point DESTINATION at SOURCE, but never clobber a file this repo does not own.
# A regular file is left alone, and so is a symlink resolving outside
# MANAGED_PREFIX; both warn and skip. MANAGED_PREFIX is matched as a literal
# prefix of the existing link target, which is what lets a renamed target
# (ai/CLAUDE.md to ai/AGENTS.md) still count as ours and get upgraded in place.
#
# Returns 0 when DESTINATION points at SOURCE and 1 when the link was skipped, so
# callers can report what actually happened instead of announcing success either
# way. Callers under `set -e` must therefore invoke this in an `if` or `||`
# context; a bare call aborts the script on the first destination it cannot own.
install_managed_link() {
	local source_path="$1"
	local destination="$2"
	local managed_prefix="$3"
	if [ -e "$destination" ] && [ ! -L "$destination" ]; then
		warning "$destination is not a symlink; skipping"
		return 1
	elif [ -L "$destination" ]; then
		case "$(readlink "$destination")" in
		"$managed_prefix"*) ln -sfn "$source_path" "$destination" ;;
		*)
			warning "$destination is unmanaged; skipping"
			return 1
			;;
		esac
	else
		ln -s "$source_path" "$destination"
	fi
}

# remove_managed_link DESTINATION MANAGED_PREFIX [MANAGED_PREFIX...]
#
# Delete DESTINATION when it is a symlink this repo owns, meaning its target starts
# with one of the MANAGED_PREFIX values. Prefixes are matched the same way
# install_managed_link matches them, so the two agree on what "ours" means.
#
# Returns 0 when DESTINATION is gone, whether it was removed or was never there, and
# 1 when something this repo does not own still occupies it, so callers can warn
# about what they left behind. Callers under `set -e` must invoke this in an `if` or
# `||` context; a bare call aborts on the first destination it cannot own.
remove_managed_link() {
	local destination="$1"
	shift
	local link_target prefix
	if [ -L "$destination" ]; then
		link_target=$(readlink "$destination")
		for prefix in "$@"; do
			case "$link_target" in
			"$prefix"*)
				rm -f "$destination"
				return 0
				;;
			esac
		done
	fi
	# A dangling symlink fails -e, so both tests are needed to spot a survivor.
	[ -e "$destination" ] || [ -L "$destination" ] || return 0
	return 1
}
