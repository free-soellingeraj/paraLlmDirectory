#!/usr/bin/env bash

set -u

# Get display string for a pane by index
# Called by tmux pane-border-format: #(/path/to/get-pane-display.sh #{pane_index})
# Returns the content of the pane's display file, or "unknown" if not found

pane_index="$1"
window="${2:-command-center}"

# Find PARA_LLM_ROOT via bootstrap file for persistent storage
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    display_dir="$PARA_LLM_ROOT/recovery/pane-display"
else
    display_dir="/tmp/claude-pane-display"  # fallback for uninstalled state
fi

# Get pane_id for the given index
pane_id=$(tmux list-panes -t "$window" -F '#{pane_index}|#{pane_id}' 2>/dev/null | grep "^${pane_index}|" | cut -d'|' -f2)

if [[ -n "$pane_id" ]]; then
    # Strip the % prefix from pane_id
    safe_id="${pane_id#%}"

    # Read and output the display file
    if [[ -f "$display_dir/$safe_id" ]]; then
        cat "$display_dir/$safe_id"
        exit 0
    fi
fi

# Fallback
echo "unknown"
