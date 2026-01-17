#!/bin/bash

# Command Center - Tiled view of all environment windows
# Moves actual panes into a tiled layout for direct interaction
# Usage: Called via Ctrl+b v keybinding

ENVS_DIR="$HOME/code/envs"
COMMAND_CENTER="command-center"
STATE_FILE="/tmp/tmux-command-center-state-$$"

# Discover all tmux windows that match env directory patterns
discover_windows() {
    local all_windows
    all_windows=$(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name} #{pane_id}' 2>/dev/null)

    for env in "$ENVS_DIR"/*/; do
        [[ ! -d "$env" ]] && continue

        local env_name
        env_name=$(basename "$env")
        local branch
        branch="${env_name#*-}"

        # Look for window with this name (branch in middle, pane_id at end)
        local match
        match=$(echo "$all_windows" | grep " ${branch} " | head -1)

        if [[ -n "$match" ]]; then
            local pane_id window_name session_window
            pane_id=$(echo "$match" | awk '{print $3}')
            window_name=$(echo "$match" | awk '{print $2}')
            session_window=$(echo "$match" | awk '{print $1}')

            # Don't include command center itself
            if [[ "$window_name" != "$COMMAND_CENTER" ]]; then
                echo "$pane_id|$window_name|$session_window"
            fi
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
        echo "No environment windows found."
        echo "Use Ctrl+b c to create one."
        read -r -n 1
        exit 0
    fi

    # Create new window for command center
    tmux new-window -n "$COMMAND_CENTER"

    # Save state: which panes we're borrowing and from where
    > "$STATE_FILE"

    # Join first pane (it replaces the empty shell in the new window)
    local first="${windows[0]}"
    local first_pane first_name first_origin
    first_pane=$(echo "$first" | cut -d'|' -f1)
    first_name=$(echo "$first" | cut -d'|' -f2)
    first_origin=$(echo "$first" | cut -d'|' -f3)

    # Swap the first pane into command center
    tmux swap-pane -s "$first_pane" -t "$COMMAND_CENTER"
    echo "$first_pane|$first_name|$first_origin" >> "$STATE_FILE"

    # Join remaining panes
    for ((i=1; i<count; i++)); do
        local entry="${windows[$i]}"
        local pane_id name origin
        pane_id=$(echo "$entry" | cut -d'|' -f1)
        name=$(echo "$entry" | cut -d'|' -f2)
        origin=$(echo "$entry" | cut -d'|' -f3)

        # Join this pane into command center
        tmux join-pane -s "$pane_id" -t "$COMMAND_CENTER" -h
        echo "$pane_id|$name|$origin" >> "$STATE_FILE"
    done

    # Apply tiled layout
    tmux select-layout -t "$COMMAND_CENTER" tiled

    # Select first pane
    tmux select-pane -t "$COMMAND_CENTER.0"

    # Show help message
    tmux display-message "Command Center: $count windows | Arrow keys=navigate | ^b z=zoom | ^b q=quit (restores layout)"
}

create_command_center
