#!/bin/sh

# JSON Settings Merger Helper
# Provides functions for safely merging JSON configurations into settings files

# Merge JSON configuration into a settings file
# Usage: merge_json_settings <settings_file> <json_config> <feature_name>
# Returns: 0 on success, 1 on failure
merge_json_settings() {
    local settings_file="$1"
    local json_config="$2" 
    local feature_name="$3"
    
    # Validate parameters
    if [ -z "$settings_file" ] || [ -z "$json_config" ] || [ -z "$feature_name" ]; then
        error "merge_json_settings: Missing required parameters"
        return 1
    fi
    
    # Check if jq is available
    if ! command -v jq > /dev/null 2>&1; then
        warning "jq not found - ${feature_name} configuration skipped"
        info "Install jq and re-run this script to configure ${feature_name}"
        return 1
    fi
    
    # Validate the JSON configuration
    if ! echo "$json_config" | jq empty > /dev/null 2>&1; then
        warning "Invalid ${feature_name} JSON configuration - skipping"
        return 1
    fi
    
    # Ensure settings file exists
    if [ ! -f "$settings_file" ]; then
        echo '{"model": "sonnet"}' > "$settings_file"
        info "Created initial settings.json"
    fi
    
    # Merge configuration into existing settings
    if ! jq ". + $json_config" "$settings_file" > "${settings_file}.tmp" 2>/dev/null; then
        rm -f "${settings_file}.tmp"
        warning "Failed to merge ${feature_name} configuration"
        return 1
    fi
    
    # Validate the merged result
    if ! jq empty "${settings_file}.tmp" > /dev/null 2>&1; then
        rm -f "${settings_file}.tmp"
        warning "Generated invalid JSON - ${feature_name} configuration skipped"
        return 1
    fi
    
    # Atomically replace the settings file
    mv "${settings_file}.tmp" "$settings_file"
    return 0
}