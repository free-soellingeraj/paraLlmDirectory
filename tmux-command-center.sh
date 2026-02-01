#!/usr/bin/env bash

set -u

# Command Center - Tiled view of all windows in the current session
# Moves actual panes into a tiled layout for direct interaction
# Usage: Called via Ctrl+b v keybinding

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND_CENTER="command-center"
SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null)

# Find PARA_LLM_ROOT via bootstrap file for persistent storage
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    PANE_DISPLAY_DIR="$PARA_LLM_ROOT/recovery/pane-display"
    # Store state file in persistent location (survives reboot)
    STATE_FILE="$PARA_LLM_ROOT/recovery/command-center-state-${SESSION_NAME}"
else
    PANE_DISPLAY_DIR="/tmp/claude-pane-display"  # fallback for uninstalled state
    STATE_FILE="/tmp/tmux-command-center-state-${SESSION_NAME}"
fi

# Plugin paths
MONITOR_PLUGIN="$SCRIPT_DIR/plugins/claude-state-monitor/monitor-manager.sh"

# Check if command center already exists
command_center_exists() {
    tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$COMMAND_CENTER"
}

# Check if we're currently in the command center
in_command_center() {
    local current_window
    current_window=$(tmux display-message -p '#{window_name}' 2>/dev/null)
    [[ "$current_window" == "$COMMAND_CENTER" ]]
}

# Switch to the command center window
goto_command_center() {
    tmux select-window -t "$COMMAND_CENTER"
}

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
    tmux set-hook -gu window-unlinked
}

# Stop the state monitor plugin
stop_state_monitor() {
    if [[ -x "$MONITOR_PLUGIN" ]]; then
        "$MONITOR_PLUGIN" detach "$COMMAND_CENTER" >/dev/null 2>&1
    fi
}

# Restore panes to their original windows and close command center
restore_command_center() {
    # Stop the monitor first
    stop_state_monitor

    # Clean up hooks
    cleanup_hooks

    # Safety check: need state file to restore
    # If no state file, create one from current panes (best-effort recovery)
    if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
        tmux display-message "Recovering: creating state from current panes..."
        # Create state file from current command center panes
        mkdir -p "$(dirname "$STATE_FILE")"
        tmux list-panes -t "$COMMAND_CENTER" -F '#{pane_id}|#{pane_current_path}' 2>/dev/null | while IFS='|' read -r pane_id pane_path; do
            # Extract project name (last component of path) and use as window name
            local project branch
            project=$(basename "$pane_path")
            # Try to get branch from git
            branch=$(git -C "$pane_path" branch --show-current 2>/dev/null || echo "unknown")
            echo "${pane_id}|${branch}|recovered|${project}"
        done > "$STATE_FILE"
        # If still no content, we can't proceed
        if [[ ! -s "$STATE_FILE" ]]; then
            tmux display-message "No panes found in command center to restore"
            rm -f "$STATE_FILE"
            return 1
        fi
    fi

    # Count panes we need to restore
    local total_panes
    total_panes=$(wc -l < "$STATE_FILE" | tr -d ' ')

    # Restore panes from state file
    local restored=0
    local first_restored_window=""

    while IFS='|' read -r pane_id name origin project; do
        [[ -z "$pane_id" ]] && continue

        # Check if this pane still exists
        if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane_id"; then
            # Break pane out to a new window with its original name
            if tmux break-pane -s "$pane_id" -n "$name" 2>/dev/null; then
                ((restored++))
                # Remember first restored window
                if [[ -z "$first_restored_window" ]]; then
                    first_restored_window="$name"
                fi
            fi
        fi
    done < "$STATE_FILE"

    # Command center should be auto-killed when last pane is broken out
    # But try to kill it anyway in case it still exists
    if command_center_exists; then
        tmux kill-window -t "$COMMAND_CENTER" 2>/dev/null
    fi

    # Clean up state file
    rm -f "$STATE_FILE"

    # Select first window AFTER everything else is done
    # Use run-shell -b to defer this until after current run-shell completes
    if [[ -n "$first_restored_window" ]]; then
        tmux run-shell -b "sleep 0.1; tmux select-window -t '$first_restored_window' 2>/dev/null"
    fi
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

    # Get the empty shell pane that was auto-created
    local empty_pane
    empty_pane=$(tmux display-message -t "$COMMAND_CENTER" -p '#{pane_id}')

    # Save state: which panes we're borrowing and from where
    : > "$STATE_FILE"

    # Join ALL panes into command center (this kills their original windows)
    for entry in "${windows[@]}"; do
        local pane_id name origin project
        pane_id=$(echo "$entry" | cut -d'|' -f1)
        name=$(echo "$entry" | cut -d'|' -f2)
        origin=$(echo "$entry" | cut -d'|' -f3)
        project=$(echo "$entry" | cut -d'|' -f4)

        # Join this pane into command center
        tmux join-pane -s "$pane_id" -t "$COMMAND_CENTER" -h
        echo "$pane_id|$name|$origin|$project" >> "$STATE_FILE"
    done

    # Kill the empty shell pane that was auto-created with the window
    tmux kill-pane -t "$empty_pane" 2>/dev/null

    # Apply tiled layout
    tmux select-layout -t "$COMMAND_CENTER" tiled

    # Enable pane border status to show window names at top of each tile
    tmux set-window-option -t "$COMMAND_CENTER" pane-border-status top
    # Use dynamic format that reads from display files written by the state monitor
    # Helper script looks up pane_id by index and reads the corresponding display file
    # #{?pane_active,** , } adds ** around active pane (handled by tmux, not script)
    local display_helper="$SCRIPT_DIR/plugins/claude-state-monitor/get-pane-display.sh"
    tmux set-window-option -t "$COMMAND_CENTER" pane-border-format \
        "#{?pane_active,** , }#{pane_index}: #($display_helper #{pane_index})#{?pane_active, **,} "

    # Initialize display files with project | branch before monitor starts
    mkdir -p "$PANE_DISPLAY_DIR"
    while IFS='|' read -r pane_id name origin project; do
        local safe_id="${pane_id//\%/}"
        echo "${project} | ${name}" > "$PANE_DISPLAY_DIR/$safe_id"
    done < "$STATE_FILE"

    # Select first pane
    tmux select-pane -t "$COMMAND_CENTER.0"

    # Hooks disabled for stability - can be re-enabled later
    # setup_hooks

    # Show help message - remind user to use Ctrl+b v to close safely
    tmux display-message "Command Center: $count windows | ^b v=close safely | ^b z=zoom | ^b b=broadcast"

    # Start Claude state monitor in background
    start_state_monitor
}

# Start the Claude state monitor plugin (fully backgrounded)
start_state_monitor() {
    if [[ -x "$MONITOR_PLUGIN" ]]; then
        # Run in background, fully detached from this script
        nohup "$MONITOR_PLUGIN" attach "$COMMAND_CENTER" </dev/null >/dev/null 2>&1 &
    elif [[ -f "$MONITOR_PLUGIN" ]]; then
        chmod +x "$MONITOR_PLUGIN" 2>/dev/null
        nohup "$MONITOR_PLUGIN" attach "$COMMAND_CENTER" </dev/null >/dev/null 2>&1 &
    fi
}

# Main: Smart command center toggle
if command_center_exists; then
    if in_command_center; then
        # In command center: close it and restore panes
        restore_command_center
    else
        # Not in command center but it exists: switch to it
        goto_command_center
    fi
else
    # No command center: create it
    create_command_center
fi
