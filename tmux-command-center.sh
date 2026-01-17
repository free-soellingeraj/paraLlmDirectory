#!/bin/bash

# Command Center - View all running Claude AI sessions in a tiled tmux view
# Usage: Called via Ctrl+b v keybinding

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVS_DIR="$HOME/code/envs"
COMMAND_CENTER_NAME="command-center"

# Discover all tmux windows that match env directory patterns (Claude sessions)
discover_claude_sessions() {
    local sessions=()

    # Get all tmux windows with their details
    local all_windows
    all_windows=$(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name} #{pane_id}' 2>/dev/null)

    # Find windows with names matching branch directories in envs/
    for env in "$ENVS_DIR"/*/; do
        [[ ! -d "$env" ]] && continue

        # Extract branch name from env directory (project-branch -> branch)
        local env_name
        env_name=$(basename "$env")
        # Extract everything after the first dash as branch name
        local branch
        branch="${env_name#*-}"

        # Look for window with this exact name
        local match
        match=$(echo "$all_windows" | grep " ${branch}$" | head -1)

        if [[ -n "$match" ]]; then
            # Format: session:window_index window_name pane_id
            local target_pane
            target_pane=$(echo "$match" | awk '{print $3}')
            local window_name
            window_name=$(echo "$match" | awk '{print $2}')
            local session_window
            session_window=$(echo "$match" | awk '{print $1}')

            # Don't include command center itself
            if [[ "$window_name" != "$COMMAND_CENTER_NAME" ]]; then
                sessions+=("$target_pane|$window_name|$session_window")
            fi
        fi
    done

    # Return sessions array
    printf '%s\n' "${sessions[@]}"
}

# Show empty state message
show_empty_state() {
    clear
    echo ""
    echo "  ╔═══════════════════════════════════════════════════════════╗"
    echo "  ║               Command Center - No Sessions                 ║"
    echo "  ╠═══════════════════════════════════════════════════════════╣"
    echo "  ║                                                           ║"
    echo "  ║  No active Claude sessions found.                         ║"
    echo "  ║                                                           ║"
    echo "  ║  To create a new session:                                 ║"
    echo "  ║    Press Ctrl+b c to create a new feature branch          ║"
    echo "  ║                                                           ║"
    echo "  ║  Sessions are detected by matching tmux window names      ║"
    echo "  ║  to directories in ~/code/envs/                           ║"
    echo "  ║                                                           ║"
    echo "  ╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Press any key to close..."
    read -r -n 1
    exit 0
}

# Create the command center with tiled panes
create_command_center() {
    local sessions=()

    # Read sessions into array
    while IFS= read -r line; do
        [[ -n "$line" ]] && sessions+=("$line")
    done < <(discover_claude_sessions)

    local session_count=${#sessions[@]}

    # Handle empty state
    if [[ $session_count -eq 0 ]]; then
        show_empty_state
        return
    fi

    # Create command center window
    tmux new-window -n "$COMMAND_CENTER_NAME"

    # Get the base pane of the new window
    local base_pane
    base_pane=$(tmux display-message -p '#{pane_id}')

    # Start the monitor for the first session in the base pane
    local first_session="${sessions[0]}"
    local first_pane_id first_name
    first_pane_id=$(echo "$first_session" | cut -d'|' -f1)
    first_name=$(echo "$first_session" | cut -d'|' -f2)

    tmux send-keys -t "$base_pane" "\"$SCRIPT_DIR/pane-monitor.sh\" \"$first_pane_id\" \"$first_name\"" Enter

    # Create additional panes for remaining sessions
    for ((i=1; i<session_count; i++)); do
        local session="${sessions[$i]}"
        local pane_id name
        pane_id=$(echo "$session" | cut -d'|' -f1)
        name=$(echo "$session" | cut -d'|' -f2)

        # Split and start monitor
        tmux split-window -t "$COMMAND_CENTER_NAME"
        tmux send-keys "\"$SCRIPT_DIR/pane-monitor.sh\" \"$pane_id\" \"$name\"" Enter
    done

    # Apply tiled layout based on session count
    apply_layout "$session_count"

    # Set up status bar to show mode
    update_status_bar "$session_count"

    # Select first pane
    tmux select-pane -t "$COMMAND_CENTER_NAME.0"
}

# Apply appropriate layout based on number of sessions
apply_layout() {
    local count=$1

    case $count in
        1)
            # Single pane, no layout needed
            ;;
        2)
            tmux select-layout -t "$COMMAND_CENTER_NAME" even-horizontal
            ;;
        *)
            tmux select-layout -t "$COMMAND_CENTER_NAME" tiled
            ;;
    esac
}

# Update the status bar to show command center info
update_status_bar() {
    local count=$1
    local mode="FOCUSED"

    # Check if synchronize-panes is on
    local sync_status
    sync_status=$(tmux show-window-option -t "$COMMAND_CENTER_NAME" synchronize-panes 2>/dev/null | grep -c "on")

    if [[ "$sync_status" -gt 0 ]]; then
        mode="BROADCAST"
    fi

    # Set window-specific status
    tmux set-window-option -t "$COMMAND_CENTER_NAME" window-status-current-format \
        "#[fg=white,bg=blue] [$mode] $count sessions #[default]"
}

# Toggle broadcast mode
toggle_broadcast() {
    local current_window
    current_window=$(tmux display-message -p '#{window_name}')

    if [[ "$current_window" != "$COMMAND_CENTER_NAME" ]]; then
        tmux display-message "Broadcast toggle only works in command-center window"
        return
    fi

    tmux set-window-option synchronize-panes

    # Update display
    local sync_status
    sync_status=$(tmux show-window-option synchronize-panes 2>/dev/null | grep -c "on")

    if [[ "$sync_status" -gt 0 ]]; then
        tmux display-message "Broadcast mode: ON - Input goes to ALL panes"
    else
        tmux display-message "Focused mode: ON - Input goes to active pane only"
    fi
}

# Main entry point
main() {
    case "${1:-}" in
        --toggle-broadcast)
            toggle_broadcast
            ;;
        *)
            create_command_center
            ;;
    esac
}

main "$@"
