#!/bin/bash

ENVS_DIR="$HOME/code/envs"

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
                    tmux kill-window
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

                # Kill any tmux windows with this branch name
                tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null | \
                    grep " ${BRANCH_NAME}$" | \
                    cut -d' ' -f1 | \
                    while read -r win; do
                        tmux kill-window -t "$win" 2>/dev/null
                    done

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
