#!/usr/bin/env bash

# Pane State Detector - Simple terminal-based state detection
# Detects whether a pane is waiting for input or actively working
#
# For Claude sessions: checks if prompt (❯) is visible
# For regular terminals: checks if shell has child processes
#
# Usage: state-detector.sh <pane_id> <project> <branch>

set -u

# Get pane ID and ensure it has the % prefix for tmux commands
RAW_PANE_ID="${1:?Usage: state-detector.sh <pane_id> <project> <branch>}"
if [[ "$RAW_PANE_ID" != %* ]]; then
    PANE_ID="%$RAW_PANE_ID"
else
    PANE_ID="$RAW_PANE_ID"
fi
PROJECT="${2:-unknown}"
BRANCH="${3:-unknown}"

# Configuration
POLL_INTERVAL=0.3                         # Fast polling for responsive updates
PANE_MAPPING_DIR="/tmp/claude-pane-mapping"

# Find PARA_LLM_ROOT via bootstrap file for persistent storage
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    DISPLAY_DIR="$PARA_LLM_ROOT/recovery/pane-display"
else
    DISPLAY_DIR="/tmp/claude-pane-display"  # fallback for uninstalled state
fi

# Colors for pane borders
COLOR_READY="green"
COLOR_WORKING="yellow"

# Status labels
LABEL_READY="Waiting for Input"
LABEL_WORKING="Working"

# State tracking
CURRENT_STATE=""

# Ensure directories exist
mkdir -p "$DISPLAY_DIR"
mkdir -p "$PANE_MAPPING_DIR/by-cwd"

# Create pane mapping file indexed by CWD
# This allows state-tracker.sh (called by Claude hooks) to find the pane
create_pane_mapping() {
    local pane_cwd
    pane_cwd=$(tmux display-message -p -t "$PANE_ID" '#{pane_current_path}' 2>/dev/null)

    if [[ -n "$pane_cwd" ]]; then
        # Create sanitized filename from CWD (same logic as state-tracker.sh)
        local cwd_safe
        cwd_safe=$(echo "$pane_cwd" | sed 's|/|_|g' | sed 's|^_||')
        local mapping_file="$PANE_MAPPING_DIR/by-cwd/$cwd_safe"

        # Write mapping in KEY=VALUE format for state-tracker.sh
        cat > "$mapping_file" << EOF
PANE_ID=$PANE_ID
PROJECT=$PROJECT
BRANCH=$BRANCH
EOF
    fi
}

# Initialize pane mapping
create_pane_mapping

# Check if Claude prompt (❯) is at the start of a line (active prompt, not in history)
is_prompt_visible() {
    local pane_content
    pane_content=$(tmux capture-pane -t "$PANE_ID" -p -S -3 2>/dev/null)

    # Look for ❯ at the start of a line (with optional leading spaces)
    # This distinguishes the active prompt from ❯ embedded in conversation history
    if echo "$pane_content" | grep -qE '^[[:space:]]*❯'; then
        return 0  # Active prompt visible
    else
        return 1  # No active prompt
    fi
}

# Get pane's shell PID
get_pane_pid() {
    tmux display-message -p -t "$PANE_ID" '#{pane_pid}' 2>/dev/null
}

# Check if shell has child processes (command running)
has_child_processes() {
    local pane_pid="$1"

    if [[ -z "$pane_pid" ]]; then
        return 1
    fi

    if pgrep -P "$pane_pid" > /dev/null 2>&1; then
        return 0  # Has children = command running
    else
        return 1  # No children = idle
    fi
}

# Check if this looks like a Claude Code session
is_claude_session() {
    local pane_content
    pane_content=$(tmux capture-pane -t "$PANE_ID" -p -S -30 2>/dev/null)

    # Look for Claude-specific patterns: prompt at line start, or Claude output markers
    if echo "$pane_content" | grep -qE '^[[:space:]]*❯|^⏺|^⎿|^✽'; then
        return 0  # Has Claude markers
    fi
    return 1
}

# Detect state for this pane
detect_state() {
    if is_claude_session; then
        # Claude session: check prompt visibility
        if is_prompt_visible; then
            echo "ready"
        else
            echo "working"
        fi
    else
        # Regular terminal: check for running commands
        local pane_pid
        pane_pid=$(get_pane_pid)

        if has_child_processes "$pane_pid"; then
            echo "working"
        else
            echo "ready"
        fi
    fi
}

# Update pane border style
update_border_style() {
    local state="$1"
    local color

    case "$state" in
        ready)   color="$COLOR_READY" ;;
        working) color="$COLOR_WORKING" ;;
        *)       color="$COLOR_WORKING" ;;
    esac

    tmux set-option -p -t "$PANE_ID" pane-border-style "fg=$color" 2>/dev/null
}

# Write display string for pane-border-format
write_display() {
    local state="$1"
    local color

    case "$state" in
        ready)   color="$COLOR_READY" ;;
        working) color="$COLOR_WORKING" ;;
        *)       color="$COLOR_WORKING" ;;
    esac

    local label
    case "$state" in
        ready)   label="$LABEL_READY" ;;
        working) label="$LABEL_WORKING" ;;
        *)       label="$LABEL_WORKING" ;;
    esac

    local display="#[fg=$color]$label | $PROJECT | $BRANCH#[default]"
    local safe_id="${PANE_ID//\%/}"
    echo "$display" > "$DISPLAY_DIR/$safe_id"
}

# Update if state changed
update_state() {
    local state
    state=$(detect_state)

    if [[ "$state" != "$CURRENT_STATE" ]]; then
        CURRENT_STATE="$state"
        update_border_style "$state"
        write_display "$state"
    fi
}

# Cleanup on exit
cleanup() {
    tmux set-option -p -t "$PANE_ID" -u pane-border-style 2>/dev/null

    # Remove display file for this pane
    local safe_id="${PANE_ID//\%/}"
    rm -f "$DISPLAY_DIR/$safe_id" 2>/dev/null

    # Remove pane mapping file
    local pane_cwd
    pane_cwd=$(tmux display-message -p -t "$PANE_ID" '#{pane_current_path}' 2>/dev/null)
    if [[ -n "$pane_cwd" ]]; then
        local cwd_safe
        cwd_safe=$(echo "$pane_cwd" | sed 's|/|_|g' | sed 's|^_||')
        rm -f "$PANE_MAPPING_DIR/by-cwd/$cwd_safe" 2>/dev/null
    fi

    exit 0
}

trap cleanup EXIT INT TERM

# Initialize
write_display "working"
CURRENT_STATE="working"

# Main loop: simple polling
while true; do
    update_state
    sleep "$POLL_INTERVAL"
done
