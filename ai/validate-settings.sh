#!/bin/sh

export ZSH=$HOME/.dotfiles

# Source helper functions
. $ZSH/ai/helpers/output.sh

info "Validating Claude settings…"

SETTINGS_FILE="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
    error "Settings file not found: $SETTINGS_FILE"
    exit 1
fi

# Check if jq is available
if ! command -v jq > /dev/null 2>&1; then
    error "jq not found - required for settings validation"
    exit 1
fi

# Validate JSON structure
if ! jq empty "$SETTINGS_FILE" > /dev/null 2>&1; then
    error "Settings file contains invalid JSON"
    exit 1
fi

success "Settings file has valid JSON"

# Check key components
echo ""
info "Checking permissions configuration:"

if jq -e '.permissions.allow' "$SETTINGS_FILE" > /dev/null 2>&1; then
    ALLOW_COUNT=$(jq '.permissions.allow | length' "$SETTINGS_FILE")
    success "Found $ALLOW_COUNT allowed tools"
    
    # Check for specific development tools
    if jq -e '.permissions.allow[] | select(. == "Bash(mypy:*)")' "$SETTINGS_FILE" > /dev/null 2>&1; then
        success "✓ mypy auto-approved"
    else
        warning "✗ mypy not auto-approved"
    fi
    
    if jq -e '.permissions.allow[] | select(. == "Bash(pytest:*)")' "$SETTINGS_FILE" > /dev/null 2>&1; then
        success "✓ pytest auto-approved"
    else
        warning "✗ pytest not auto-approved"
    fi
    
    if jq -e '.permissions.allow[] | select(. == "mcp__github__get_file_contents")' "$SETTINGS_FILE" > /dev/null 2>&1; then
        success "✓ GitHub MCP tools auto-approved"
    else
        warning "✗ GitHub MCP tools not auto-approved"
    fi
    
else
    warning "No permissions.allow array found"
fi

if jq -e '.permissions.deny' "$SETTINGS_FILE" > /dev/null 2>&1; then
    DENY_COUNT=$(jq '.permissions.deny | length' "$SETTINGS_FILE")
    info "Found $DENY_COUNT denied tools"
else
    info "No permissions.deny array found"
fi

echo ""
info "Checking hooks configuration:"

if jq -e '.hooks.PostToolUse' "$SETTINGS_FILE" > /dev/null 2>&1; then
    HOOK_COUNT=$(jq '.hooks.PostToolUse | length' "$SETTINGS_FILE")
    success "Found $HOOK_COUNT post-tool-use hooks configured"
else
    warning "No post-tool-use hooks configured"
fi

echo ""
success "Settings validation complete!"