#!/bin/bash

# Command Center - Tiled view of all windows in the current session
# Moves actual panes into a tiled layout for direct interaction
# Usage: Called via Ctrl+b v keybinding

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND_CENTER="command-center"
STATE_FILE="/tmp/tmux-command-center-state-$$"
MONITOR_PID_FILE="/tmp/tmux-claude-monitor-pid"

# Set up hooks for dynamic window/pane management
setup_hooks() {
    local hooks_script="$SCRIPT_DIR/tmux-cc-hooks.sh"

    # Hook: when a new window is created, join it to command center
    tmux set-hook -g after-new-window "run-shell 'bash \"$hooks_script\" new-window'"

    # Hook: when a pane exits, reapply the tiled layout
    tmux set-hook -g pane-exited "run-shell 'bash \"$hooks_script\" pane-exited'"

    # Hook: when a window is closed, check if we need to clean up hooks
    tmux set-hook -g window-unlinked "run-shell 'bash \"$hooks_script\" window-unlinked'"
}

# Remove hooks when command center is closed
cleanup_hooks() {
    tmux set-hook -gu after-new-window
    tmux set-hook -gu pane-exited
}

# Discover all tmux windows in the current session (excluding command center)
discover_windows() {
    local current_session
    current_session=$(tmux display-message -p '#{session_name}')

    # List all windows in current session: session:index window_name pane_id pane_current_path
    tmux list-windows -t "$current_session" -F '#{session_name}:#{window_index} #{window_name} #{pane_id} #{pane_current_path}' 2>/dev/null | \
    while read -r session_window window_name pane_id pane_path; do
        # Don't include command center itself
        if [[ "$window_name" != "$COMMAND_CENTER" ]]; then
            # Extract project name from path (last directory component)
            local project
            project=$(basename "$pane_path")
            echo "$pane_id|$window_name|$session_window|$project"
        fi
    done
}

# Save state and create command center
create_command_center() {
    local windows=()

    while IFS= read -r line; do
        [[ -n "$line" ]] && windows+=("$line")
    done < <(discover_windows | sort -u)

    local count=${#windows[@]}

    if [[ $count -eq 0 ]]; then
        echo "No windows found (besides command center)."
        echo "Create a window first with Ctrl+b c or standard tmux commands."
        read -r -n 1
        exit 0
    fi

    # Create new window for command center
    tmux new-window -n "$COMMAND_CENTER"

    # Save state: which panes we're borrowing and from where
    > "$STATE_FILE"

    # Join first pane (it replaces the empty shell in the new window)
    local first="${windows[0]}"
    local first_pane first_name first_origin first_project
    first_pane=$(echo "$first" | cut -d'|' -f1)
    first_name=$(echo "$first" | cut -d'|' -f2)
    first_origin=$(echo "$first" | cut -d'|' -f3)
    first_project=$(echo "$first" | cut -d'|' -f4)

    # Swap the first pane into command center
    tmux swap-pane -s "$first_pane" -t "$COMMAND_CENTER"
    echo "$first_pane|$first_name|$first_origin|$first_project" >> "$STATE_FILE"

    # Join remaining panes
    for ((i=1; i<count; i++)); do
        local entry="${windows[$i]}"
        local pane_id name origin project
        pane_id=$(echo "$entry" | cut -d'|' -f1)
        name=$(echo "$entry" | cut -d'|' -f2)
        origin=$(echo "$entry" | cut -d'|' -f3)
        project=$(echo "$entry" | cut -d'|' -f4)

        # Join this pane into command center
        tmux join-pane -s "$pane_id" -t "$COMMAND_CENTER" -h
        echo "$pane_id|$name|$origin|$project" >> "$STATE_FILE"
    done

    # Apply tiled layout
    tmux select-layout -t "$COMMAND_CENTER" tiled

    # Enable pane border status to show window names at top of each tile
    tmux set-window-option -t "$COMMAND_CENTER" pane-border-status top
    tmux set-window-option -t "$COMMAND_CENTER" pane-border-format " #{pane_index}: #T "

    # Set pane titles with format: project | branch
    local pane_index=0
    while IFS='|' read -r pane_id name origin project; do
        local title="${project} | ${name}"
        tmux select-pane -t "$COMMAND_CENTER.$pane_index" -T "$title"
        ((pane_index++))
    done < "$STATE_FILE"

    # Select first pane
    tmux select-pane -t "$COMMAND_CENTER.0"

    # Set up hooks for dynamic updates
    setup_hooks

    # Show help message
    tmux display-message "Command Center: $count windows | Arrows=navigate | ^b z=zoom | ^b b=broadcast"

    # Start Claude state monitor in background
    start_state_monitor
}

# Start the Claude state monitor for visual feedback
start_state_monitor() {
    # Kill any existing monitor
    if [[ -f "$MONITOR_PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null
        fi
    fi

    # Start new monitor
    if [[ -x "$SCRIPT_DIR/claude-state-monitor.sh" ]]; then
        "$SCRIPT_DIR/claude-state-monitor.sh" "$COMMAND_CENTER" &
        echo $! > "$MONITOR_PID_FILE"
    fi
}

create_command_center
