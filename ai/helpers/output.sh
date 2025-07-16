#!/bin/sh

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output functions
error() {
    echo "${RED}Error: $1${NC}" >&2
}

warning() {
    echo "${YELLOW}Warning: $1${NC}"
}

success() {
    echo "${GREEN}✓ $1${NC}"
}

info() {
    echo "${BLUE}$1${NC}"
}

# Exit with error message
die() {
    error "$1"
    exit 1
}