#!/bin/bash

# Pane Monitor - Mirrors a target tmux pane with live updates
# Usage: pane-monitor.sh TARGET_PANE_ID SESSION_NAME

TARGET_PANE="${1:-}"
SESSION_NAME="${2:-unknown}"
REFRESH_INTERVAL=0.2  # 200ms

if [[ -z "$TARGET_PANE" ]]; then
    echo "Usage: pane-monitor.sh TARGET_PANE_ID [SESSION_NAME]"
    exit 1
fi

# Set pane title to show which session we're monitoring
printf '\033]2;%s\033\\' "$SESSION_NAME"

# Cleanup function
cleanup() {
    tput cnorm  # Show cursor
    exit 0
}

trap cleanup EXIT INT TERM

# Hide cursor for cleaner display
tput civis

# Track if target is still alive
check_target_alive() {
    tmux has-session -t "$TARGET_PANE" 2>/dev/null
    return $?
}

# Main monitoring loop
while true; do
    # Check if target pane still exists
    if ! check_target_alive; then
        clear
        echo ""
        echo "  ┌─────────────────────────────────────┐"
        echo "  │  Session ended: $SESSION_NAME"
        echo "  ├─────────────────────────────────────┤"
        echo "  │  The monitored session has closed.  │"
        echo "  │                                     │"
        echo "  │  Press Ctrl+c to close this pane    │"
        echo "  │  or Ctrl+b v to refresh all         │"
        echo "  └─────────────────────────────────────┘"
        echo ""

        # Wait for user to close
        while true; do
            sleep 1
        done
    fi

    # Capture the target pane content with colors
    # -p: print to stdout
    # -e: preserve escape sequences (colors)
    # -t: target pane
    content=$(tmux capture-pane -p -e -t "$TARGET_PANE" 2>/dev/null)

    # Move cursor to top-left and output content
    # Using tput for better terminal compatibility
    tput home
    echo "$content"

    # Small sleep for refresh interval
    sleep "$REFRESH_INTERVAL"
done
