#!/usr/bin/env bash
# logging.sh - Shared logging utilities for bash scripts
#
# Source this file to get colored logging functions:
#   source "${SCRIPT_DIR}/lib/logging.sh"
#
# Functions:
#   log_info    - Blue [INFO] prefix
#   log_success - Green [SUCCESS] prefix
#   log_warn    - Yellow [WARN] prefix
#   log_error   - Red [ERROR] prefix (outputs to stderr)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}
