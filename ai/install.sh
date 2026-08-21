#!/bin/sh

set -eu

AI_ROOT=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

# Both the platform selectors and the Claude-only component flags may appear in any
# position (`--uninstall --codex-only`, `--uninstall --hooks-only`), so scan the whole
# argument list rather than just $1. A selector left in the list would reach a platform
# installer that rejects it as an unknown option; forwarding a Claude-only component
# flag to install-codex.sh would either abort the run or, if it ignored the flag, widen
# the request into a full Codex install or uninstall.
platform=both
argc=$#
while [ "$argc" -gt 0 ]; do
	arg="$1"
	shift
	argc=$((argc - 1))
	case "$arg" in
	--claude-only) platform=claude ;;
	--codex-only) platform=codex ;;
	--claude-md-only | --hooks-only | --permissions-only | --cleanup)
		if [ "$platform" = both ]; then platform=claude; fi
		set -- "$@" "$arg"
		;;
	*) set -- "$@" "$arg" ;;
	esac
done

# Only the dispatcher's own help; `--claude-only --help` belongs to that installer.
if [ "$platform" = both ] && { [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; }; then
	echo "Usage: $0 [--claude-only|--codex-only] [PLATFORM OPTIONS]"
	echo ""
	echo "Installs shared AI configuration for Claude Code and Codex."
	echo "Platform component flags are forwarded to both installers."
	exit 0
fi

case "$platform" in
claude) exec "$AI_ROOT/install-claude.sh" "$@" ;;
codex) exec "$AI_ROOT/install-codex.sh" "$@" ;;
esac

"$AI_ROOT/install-claude.sh" "$@"
"$AI_ROOT/install-codex.sh" "$@"
