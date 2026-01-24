#!/usr/bin/env bash

# Pane Monitor - Mirrors a target tmux pane with live updates and input forwarding
# Usage: pane-monitor.sh TARGET_PANE_ID SESSION_NAME

TARGET_PANE="${1:-}"
SESSION_NAME="${2:-unknown}"
REFRESH_INTERVAL=0.15  # 150ms

if [[ -z "$TARGET_PANE" ]]; then
    echo "Usage: pane-monitor.sh TARGET_PANE_ID [SESSION_NAME]"
    exit 1
fi

# Colors
HEADER_BG="\033[44m"      # Blue background
HEADER_FG="\033[97m"      # Bright white text
BOLD="\033[1m"
RESET="\033[0m"
DIM="\033[2m"

# Set pane title to show which session we're monitoring
printf '\033]2;%s\033\\' "$SESSION_NAME"

# Cleanup function
cleanup() {
    stty sane 2>/dev/null  # Restore terminal settings
    tput cnorm  # Show cursor
    exit 0
}

trap cleanup EXIT INT TERM

# Hide cursor for cleaner display
tput civis

# Get terminal width for header
get_width() {
    tput cols 2>/dev/null || echo 80
}

# Draw header bar
draw_header() {
    local width
    width="$(get_width)"
    local label=" ◆ $SESSION_NAME  [typing enabled]"
    local label_len=${#label}
    local padding=$((width - label_len))
    if [[ $padding -lt 0 ]]; then padding=0; fi

    # Colored header bar spanning full width
    printf '%s%s%s%s%*s%s\n' "$HEADER_BG" "$HEADER_FG" "$BOLD" "$label" "$padding" "" "$RESET"
    # Separator line
    printf "${DIM}%*s${RESET}\n" "$width" "" | tr ' ' '─'
}

# Track if target is still alive
check_target_alive() {
    tmux has-session -t "$TARGET_PANE" 2>/dev/null
}

# Main loop with input forwarding
while true; do
    # Check if target pane still exists
    if ! check_target_alive; then
        clear
        draw_header
        echo ""
        echo "  Session ended."
        echo ""
        echo "  Press Ctrl+c to close this pane"
        echo "  or Ctrl+b v to refresh all"
        echo ""

        # Wait for user to close
        while true; do
            sleep 1
        done
    fi

    # Capture the target pane's VISIBLE content
    content=$(tmux capture-pane -p -e -t "$TARGET_PANE" 2>/dev/null)

    # Clear and redraw
    tput home
    tput ed
    draw_header
    echo "$content"

    # Read input with short timeout and forward to target pane
    # -s: silent (don't echo)
    # -n 1: read single character
    # -t: timeout (allows refresh loop to continue)
    if IFS= read -r -s -n 1 -t "$REFRESH_INTERVAL" char; then
        if [[ -z "$char" ]]; then
            # Empty char = Enter key
            tmux send-keys -t "$TARGET_PANE" Enter
        elif [[ "$char" == $'\x7f' ]] || [[ "$char" == $'\x08' ]]; then
            # Backspace
            tmux send-keys -t "$TARGET_PANE" BSpace
        elif [[ "$char" == $'\x1b' ]]; then
            # Escape sequence (arrow keys, etc.) - read the rest
            read -r -s -n 2 -t 0.01 escape_seq
            case "$escape_seq" in
                '[A') tmux send-keys -t "$TARGET_PANE" Up ;;
                '[B') tmux send-keys -t "$TARGET_PANE" Down ;;
                '[C') tmux send-keys -t "$TARGET_PANE" Right ;;
                '[D') tmux send-keys -t "$TARGET_PANE" Left ;;
                *)    tmux send-keys -t "$TARGET_PANE" Escape ;;
            esac
        elif [[ "$char" == $'\x03' ]]; then
            # Ctrl+C - forward it
            tmux send-keys -t "$TARGET_PANE" C-c
        elif [[ "$char" == $'\x04' ]]; then
            # Ctrl+D - forward it
            tmux send-keys -t "$TARGET_PANE" C-d
        else
            # Regular character - send literally
            tmux send-keys -t "$TARGET_PANE" -l "$char"
        fi
    fi
done
