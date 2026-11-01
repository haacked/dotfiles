#!/bin/sh
# claude-config-dir.sh - Where Claude Code keeps its default account.
#
# Source this file. claude uses this directory when CLAUDE_CONFIG_DIR is unset.
# The file stays POSIX sh and lives outside ai/skills, because the test that
# keeps provider-specific paths out of shared skills scans only skill folders.

# shellcheck disable=SC2034 # Sourcing scripts read it.
CLAUDE_DEFAULT_CONFIG_DIR="${HOME}/.claude"
