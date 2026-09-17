#!/usr/bin/env bash
# fs.sh - Filesystem helpers shared by bin/ scripts.
#
# Source this file to get:
#   atomic_write <path>  - Read stdin, write to <path> atomically via a
#                          tempfile on the same directory (so the rename
#                          stays on one filesystem).

atomic_write() {
  local dst="$1"
  local tmp
  tmp=$(mktemp "${dst}.XXXXXX")
  cat > "$tmp"
  mv "$tmp" "$dst"
}
