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
