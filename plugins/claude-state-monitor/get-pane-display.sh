#!/usr/bin/env bash

set -u

# Get display string for a pane by index
# Called by tmux pane-border-format: #(/path/to/get-pane-display.sh #{pane_index})
# Returns the content of the pane's display file, or "unknown" if not found

pane_index="$1"
window="${2:-command-center}"
display_dir="/tmp/claude-pane-display"

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
