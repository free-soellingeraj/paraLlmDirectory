#!/bin/bash

CODE_DIR="$HOME/code"
ENVS_DIR="$HOME/code/envs"

# Ensure envs directory exists
mkdir -p "$ENVS_DIR"

# Check if we're currently in command center (matches cleanup script approach)
COMMAND_CENTER="command-center"
DEBUG_LOG="/tmp/new-branch-debug.log"

in_command_center() {
    local current_window
    current_window=$(tmux display-message -p '#{window_name}' 2>/dev/null)
    echo "$(date): in_command_center check: current_window='$current_window' COMMAND_CENTER='$COMMAND_CENTER'" >> "$DEBUG_LOG"
    [[ "$current_window" == "$COMMAND_CENTER" ]]
}

# Create a new window for a feature branch
# If command center is active, joins the pane to it instead
# Usage: create_feature_window "branch-name" "/path/to/dir"
create_feature_window() {
    local branch_name="$1"
    local working_dir="$2"
    local project_name
    project_name=$(basename "$working_dir")

    echo "$(date): create_feature_window called: branch='$branch_name' dir='$working_dir'" >> "$DEBUG_LOG"
    if in_command_center; then
        echo "$(date): IN command center - will join pane" >> "$DEBUG_LOG"
        # In command center - create window then join to command center
        tmux new-window -n "$branch_name" -c "$working_dir"
        local new_pane_id
        new_pane_id=$(tmux display-message -p '#{pane_id}')

        # Add to state file so it can be restored later
        local session_name
        session_name=$(tmux display-message -p '#{session_name}')
        local state_file="/tmp/tmux-command-center-state-${session_name}"
        echo "$new_pane_id|$branch_name|new|$project_name" >> "$state_file"

        # Join pane to command center
        tmux join-pane -s "$new_pane_id" -t "$COMMAND_CENTER" -h

        # Reapply tiled layout
        tmux select-layout -t "$COMMAND_CENTER" tiled

        # Initialize display file for the new pane
        local safe_id="${new_pane_id//\%/}"
        mkdir -p /tmp/claude-pane-display
        echo "Waiting for Input | $project_name | $branch_name" > "/tmp/claude-pane-display/$safe_id"

        # Start state monitor for the new pane
        local monitor_script
        monitor_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugins/claude-state-monitor/state-detector.sh"
        if [[ -x "$monitor_script" ]]; then
            nohup "$monitor_script" "$new_pane_id" "$project_name" "$branch_name" </dev/null >/dev/null 2>&1 &
        fi

        # Switch to command center and select the new pane
        tmux select-window -t "$COMMAND_CENTER"
    else
        echo "$(date): NOT in command center - normal window creation" >> "$DEBUG_LOG"
        # Normal mode - just create window
        tmux new-window -n "$branch_name" -c "$working_dir"
    fi
}

# Find git repos in ~/code (base repos only - directories with .git dir at top level)
select_repo() {
    {
        echo "← Back"
        echo "⚡ Plain terminal (no project)"
        find "$CODE_DIR" -maxdepth 2 -name ".git" -type d 2>/dev/null | \
            xargs -I {} dirname {} | \
            grep "^${CODE_DIR}/[^/]*$" | \
            sed "s|${CODE_DIR}/||" | \
            sort -u
    } | fzf --prompt="Select project: " --height=40% --reverse
}

# Find existing branch clones for a specific project in envs/
select_existing_clone() {
    local project="$1"
    {
        echo "← Back"
        for dir in "$ENVS_DIR"/${project}-*/; do
            if [[ -d "$dir" ]]; then
                basename "$dir" | sed "s|^${project}-||"
            fi
        done 2>/dev/null | sort
    } | fzf --prompt="Select branch: " --height=40% --reverse
}

# Select from remote branches not yet cloned locally
select_remote_branch() {
    local repo_root="$1"
    local project="$2"

    # Fetch latest from remote
    git -C "$repo_root" fetch --prune 2>/dev/null

    # Get remote branches, excluding HEAD and already-cloned branches
    {
        echo "← Back"
        git -C "$repo_root" branch -r 2>/dev/null | \
            grep -v 'HEAD' | \
            sed 's|origin/||' | \
            sed 's/^[ *]*//' | \
            while read branch; do
                # Exclude branches that already have local clones
                if [[ ! -d "$ENVS_DIR/${project}-${branch}" ]]; then
                    echo "$branch"
                fi
            done
    } | fzf --prompt="Select remote branch: " --height=40% --reverse
}

select_resume_or_new() {
    printf "← Back\nResume - continue existing local clone\nAttach - checkout existing remote branch\nNew - create a new feature branch" | \
        fzf --prompt="What would you like to do? " --height=16% --reverse
}

# Main flow with back button support
main() {
    local step=1

    while true; do
        case $step in
            1)
                # Step 1: Select project
                REPO_NAME=$(select_repo)
                if [[ -z "$REPO_NAME" ]]; then
                    exit 0
                elif [[ "$REPO_NAME" == "← Back" ]]; then
                    exit 0  # Can't go back from first step
                elif [[ "$REPO_NAME" == "⚡ Plain terminal (no project)" ]]; then
                    # Use create_feature_window to handle command center case
                    local current_path
                    current_path=$(tmux display-message -p '#{pane_current_path}')
                    create_feature_window "terminal" "$current_path"
                    exit 0
                fi
                REPO_ROOT="${CODE_DIR}/${REPO_NAME}"
                step=2
                ;;
            2)
                # Step 2: Ask if resuming existing work
                RESUME=$(select_resume_or_new)
                if [[ -z "$RESUME" ]]; then
                    exit 0
                elif [[ "$RESUME" == "← Back" ]]; then
                    step=1
                    continue
                fi

                case "$RESUME" in
                    "Resume - continue existing local clone")
                        step=3a
                        ;;
                    "Attach - checkout existing remote branch")
                        step=3c
                        ;;
                    "New - create a new feature branch")
                        step=3b
                        ;;
                esac
                ;;
            3a)
                # Step 3a: Select existing branch for this project
                BRANCH_NAME=$(select_existing_clone "$REPO_NAME")
                if [[ -z "$BRANCH_NAME" ]]; then
                    exit 0
                elif [[ "$BRANCH_NAME" == "← Back" ]]; then
                    step=2
                    continue
                fi

                ENV_DIR="${ENVS_DIR}/${REPO_NAME}-${BRANCH_NAME}"
                CLONE_DIR="${ENV_DIR}/${REPO_NAME}"

                create_feature_window "$BRANCH_NAME" "$CLONE_DIR"
                # Run setup hook if it exists
                if [[ -f "$CLONE_DIR/paraLlm_setup.sh" ]]; then
                    tmux send-keys "./paraLlm_setup.sh && claude --dangerously-skip-permissions --resume" Enter
                else
                    tmux send-keys "claude --dangerously-skip-permissions --resume" Enter
                fi
                exit 0
                ;;
            3c)
                # Step 3c: Select existing remote branch to attach to
                BRANCH_NAME=$(select_remote_branch "$REPO_ROOT" "$REPO_NAME")
                if [[ -z "$BRANCH_NAME" ]]; then
                    exit 0
                elif [[ "$BRANCH_NAME" == "← Back" ]]; then
                    step=2
                    continue
                fi

                ENV_DIR="${ENVS_DIR}/${REPO_NAME}-${BRANCH_NAME}"
                CLONE_DIR="${ENV_DIR}/${REPO_NAME}"

                # Get the remote URL from the original repo
                cd "$REPO_ROOT" || exit 1
                REMOTE_URL=$(git remote get-url origin 2>/dev/null)

                if [[ -z "$REMOTE_URL" ]]; then
                    echo "No remote 'origin' found in $REPO_ROOT"
                    echo "Press enter to close."
                    read -r
                    exit 1
                fi

                # Create env directory and clone
                mkdir -p "$ENV_DIR"
                echo "Cloning $REPO_NAME..."
                git clone "$REMOTE_URL" "$CLONE_DIR" 2>&1

                if [[ $? -ne 0 ]]; then
                    echo "Failed to clone. Press enter to close."
                    read -r
                    rm -rf "$ENV_DIR"
                    exit 1
                fi

                cd "$CLONE_DIR" || exit 1
                git checkout "$BRANCH_NAME" 2>&1

                create_feature_window "$BRANCH_NAME" "$CLONE_DIR"
                # Run setup hook if it exists
                if [[ -f "$CLONE_DIR/paraLlm_setup.sh" ]]; then
                    tmux send-keys "./paraLlm_setup.sh && claude" Enter
                else
                    tmux send-keys "claude --dangerously-skip-permissions" Enter
                fi
                exit 0
                ;;
            3b)
                # Step 3b: Enter new branch name
                echo -n "New branch/feature name (or 'back'): "
                read -r BRANCH_NAME

                if [[ -z "$BRANCH_NAME" ]]; then
                    exit 0
                elif [[ "$BRANCH_NAME" == "back" ]]; then
                    step=2
                    continue
                fi

                ENV_DIR="${ENVS_DIR}/${REPO_NAME}-${BRANCH_NAME}"
                CLONE_DIR="${ENV_DIR}/${REPO_NAME}"

                # Check if clone already exists
                if [[ -d "$ENV_DIR" ]]; then
                    echo "Directory already exists at $ENV_DIR"
                    echo "Opening existing clone..."
                    sleep 1
                    create_feature_window "$BRANCH_NAME" "$CLONE_DIR"
                    # Run setup hook if it exists
                    if [[ -f "$CLONE_DIR/paraLlm_setup.sh" ]]; then
                        tmux send-keys "./paraLlm_setup.sh && claude --resume" Enter
                    else
                        tmux send-keys "claude --resume" Enter
                    fi
                    exit 0
                fi

                # Get the remote URL from the original repo
                cd "$REPO_ROOT" || exit 1
                REMOTE_URL=$(git remote get-url origin 2>/dev/null)

                if [[ -z "$REMOTE_URL" ]]; then
                    echo "No remote 'origin' found in $REPO_ROOT"
                    echo "Press enter to close."
                    read -r
                    exit 1
                fi

                # Create env directory and clone
                mkdir -p "$ENV_DIR"
                echo "Cloning $REPO_NAME..."
                git clone "$REMOTE_URL" "$CLONE_DIR" 2>&1

                if [[ $? -ne 0 ]]; then
                    echo "Failed to clone. Press enter to close."
                    read -r
                    rm -rf "$ENV_DIR"
                    exit 1
                fi

                cd "$CLONE_DIR" || exit 1

                # Check if branch exists on remote
                if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH_NAME}"; then
                    # Branch exists on remote, check it out
                    git checkout "$BRANCH_NAME" 2>&1
                else
                    # Branch doesn't exist, create new branch
                    git checkout -b "$BRANCH_NAME" 2>&1
                fi

                create_feature_window "$BRANCH_NAME" "$CLONE_DIR"
                # Run setup hook if it exists
                if [[ -f "$CLONE_DIR/paraLlm_setup.sh" ]]; then
                    tmux send-keys "./paraLlm_setup.sh && claude" Enter
                else
                    tmux send-keys "claude" Enter
                fi
                exit 0
                ;;
        esac
    done
}

main
