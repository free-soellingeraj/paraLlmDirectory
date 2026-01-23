#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
source "$SCRIPT_DIR/para-llm-config.sh"

COMMAND_CENTER="command-center"

# Check if we're in command center
in_command_center() {
    local current_window
    current_window=$(tmux display-message -p '#{window_name}' 2>/dev/null)
    [[ "$current_window" == "$COMMAND_CENTER" ]]
}

# Kill current pane in command center and reapply layout
kill_pane_in_command_center() {
    local active_pane
    active_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null)

    # Count panes in command center
    local pane_count
    pane_count=$(tmux list-panes -t "$COMMAND_CENTER" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$pane_count" -le 1 ]]; then
        echo "This is the last pane in command center."
        echo "Use Ctrl+b v to exit command center first."
        read -r -n 1 -s -p "Press any key to continue..."
        return 1
    fi

    # Kill the active pane
    tmux kill-pane -t "$active_pane"

    # Reapply tiled layout to reclaim space
    tmux select-layout -t "$COMMAND_CENTER" tiled

    echo "Pane closed. Command center updated."
    sleep 0.5
}

# Safe window close - don't kill if it's the last window in the session
safe_kill_window() {
    # If in command center, kill just the current pane instead
    if in_command_center; then
        kill_pane_in_command_center
        return $?
    fi

    local window_count
    window_count=$(tmux list-windows 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$window_count" -le 1 ]]; then
        echo "This is the last window in the session."
        echo "Create another window first (Ctrl+b c) or use Ctrl+b d to detach."
        read -r -n 1 -s -p "Press any key to continue..."
        return 1
    fi
    tmux kill-window
}

# List all feature environments
select_env() {
    {
        echo "← Back"
        echo "⚡ Just close window (no cleanup)"
        for dir in "$ENVS_DIR"/*/; do
            if [[ -d "$dir" ]]; then
                basename "$dir"
            fi
        done 2>/dev/null | sort
    } | fzf --prompt="Select feature to cleanup: " --height=40% --reverse
}

select_confirm() {
    printf "← Back\nNo - cancel\nYes - delete this feature" | \
        fzf --prompt="Are you sure? " --height=12% --reverse
}

select_force_confirm() {
    printf "← Back\nNo - cancel\nYes - delete anyway" | \
        fzf --prompt="Delete with unpushed commits? " --height=12% --reverse
}

main() {
    local step=1

    while true; do
        case $step in
            1)
                # Step 1: Select environment to clean up
                ENV_NAME=$(select_env)
                if [[ -z "$ENV_NAME" ]]; then
                    exit 0
                elif [[ "$ENV_NAME" == "← Back" ]]; then
                    exit 0  # Can't go back from first step
                elif [[ "$ENV_NAME" == "⚡ Just close window (no cleanup)" ]]; then
                    safe_kill_window
                    exit 0
                fi
                ENV_DIR="${ENVS_DIR}/${ENV_NAME}"
                step=2
                ;;
            2)
                # Show what will be deleted
                echo "Will delete: $ENV_DIR"
                echo ""
                ls -la "$ENV_DIR" 2>/dev/null
                echo ""

                # Step 2: Confirm deletion
                CONFIRM=$(select_confirm)
                if [[ -z "$CONFIRM" ]]; then
                    exit 0
                elif [[ "$CONFIRM" == "← Back" ]]; then
                    step=1
                    continue
                elif [[ "$CONFIRM" == "No - cancel" ]]; then
                    echo "Cancelled."
                    sleep 1
                    exit 0
                fi

                step=3
                ;;
            3)
                # Check for unpushed changes
                CLONE_DIR=$(find "$ENV_DIR" -maxdepth 1 -type d ! -name "$(basename "$ENV_DIR")" | head -1)
                if [[ -d "$CLONE_DIR/.git" ]]; then
                    cd "$CLONE_DIR"
                    UNPUSHED=$(git log --oneline @{u}.. 2>/dev/null | wc -l | tr -d ' ')
                    if [[ "$UNPUSHED" -gt 0 ]]; then
                        echo "WARNING: $UNPUSHED unpushed commit(s) detected!"
                        FORCE=$(select_force_confirm)
                        if [[ -z "$FORCE" ]]; then
                            exit 0
                        elif [[ "$FORCE" == "← Back" ]]; then
                            step=2
                            continue
                        elif [[ "$FORCE" == "No - cancel" ]]; then
                            echo "Cancelled."
                            sleep 1
                            exit 0
                        fi
                    fi
                fi

                # Extract branch name from env name (everything after first dash)
                BRANCH_NAME="${ENV_NAME#*-}"

                # Run teardown hook if it exists
                if [[ -f "$CLONE_DIR/paraLlm_teardown.sh" ]]; then
                    echo "Running teardown hook..."
                    (cd "$CLONE_DIR" && ./paraLlm_teardown.sh)
                fi

                # Kill any tmux windows/panes with this branch name
                if in_command_center; then
                    # In command center: find and kill the pane for this branch
                    # Look up pane by checking the state file
                    SESSION_NAME=$(tmux display-message -p '#{session_name}')
                    STATE_FILE="/tmp/tmux-command-center-state-${SESSION_NAME}"
                    if [[ -f "$STATE_FILE" ]]; then
                        # Find pane ID for this branch in state file
                        local pane_to_kill
                        pane_to_kill=$(grep "|${BRANCH_NAME}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f1 | head -1)
                        if [[ -n "$pane_to_kill" ]]; then
                            tmux kill-pane -t "$pane_to_kill" 2>/dev/null
                            # Reapply layout
                            tmux select-layout -t "$COMMAND_CENTER" tiled 2>/dev/null
                        fi
                    fi
                else
                    # Normal mode: kill windows by name (current session only)
                    local current_window_name
                    current_window_name=$(tmux display-message -p '#{window_name}' 2>/dev/null)
                    tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null | \
                        grep " ${BRANCH_NAME}$" | \
                        cut -d' ' -f1 | \
                        while read -r win_idx; do
                            tmux kill-window -t ":${win_idx}" 2>/dev/null
                        done
                    # Only kill current window if it was the feature window
                    if [[ "$current_window_name" == "$BRANCH_NAME" ]]; then
                        safe_kill_window
                    fi
                fi

                # Delete the environment
                echo "Deleting $ENV_DIR..."
                rm -rf "$ENV_DIR"

                if [[ $? -eq 0 ]]; then
                    echo "✓ Deleted successfully"
                else
                    echo "Failed to delete"
                fi

                sleep 1
                exit 0
                ;;
        esac
    done
}

main
