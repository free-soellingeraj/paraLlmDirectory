#!/usr/bin/env bash

set -u

# Get display string for a pane
# Called by tmux pane-border-format: #(/path/to/get-pane-display.sh #{pane_id})
# Accepts pane_id (e.g., %0, %1) directly
# Returns the content of the pane's display file, or empty string if not found

pane_id="${1:-}"

# Find PARA_LLM_ROOT via bootstrap file for persistent storage
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    display_dir="$PARA_LLM_ROOT/recovery/pane-display"
else
    display_dir="/tmp/claude-pane-display"  # fallback for uninstalled state
fi

if [[ -n "$pane_id" ]]; then
    # Strip the % prefix from pane_id
    safe_id="${pane_id#%}"

    # Read and output the display file
    if [[ -f "$display_dir/$safe_id" ]]; then
        cat "$display_dir/$safe_id"
        exit 0
    fi
fi

# Return empty - no display file means not a tracked pane
echo ""
