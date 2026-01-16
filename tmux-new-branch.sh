#!/bin/bash

CODE_DIR="$HOME/code"
ENVS_DIR="$HOME/code/envs"

# Ensure envs directory exists
mkdir -p "$ENVS_DIR"

# Find git repos in ~/code (base repos only - directories with .git dir, no dashes)
select_repo() {
    {
        echo "← Back"
        echo "⚡ Plain terminal (no project)"
        find "$CODE_DIR" -maxdepth 2 -name ".git" -type d 2>/dev/null | \
            xargs -I {} dirname {} | \
            grep "^${CODE_DIR}/[^/]*$" | \
            sed "s|${CODE_DIR}/||" | \
            grep -v '-' | \
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

select_resume_or_new() {
    printf "← Back\nNo - start new feature/bug\nYes - resume existing" | \
        fzf --prompt="Resuming existing work? " --height=12% --reverse
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
                    tmux new-window -c "#{pane_current_path}"
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

                if [[ "$RESUME" == "Yes - resume existing" ]]; then
                    step=3a
                else
                    step=3b
                fi
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

                tmux new-window -n "$BRANCH_NAME" -c "$CLONE_DIR"
                tmux send-keys "claude --resume" Enter
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
                    tmux new-window -n "$BRANCH_NAME" -c "$CLONE_DIR"
                    tmux send-keys "claude --resume" Enter
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

                tmux new-window -n "$BRANCH_NAME" -c "$CLONE_DIR"
                tmux send-keys "claude" Enter
                exit 0
                ;;
        esac
    done
}

main
