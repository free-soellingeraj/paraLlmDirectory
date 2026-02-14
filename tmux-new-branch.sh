#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
source "$SCRIPT_DIR/para-llm-config.sh"

# Ensure envs directory exists
mkdir -p "$ENVS_DIR"

# Check if we're currently in command center (matches cleanup script approach)
COMMAND_CENTER="command-center"

in_command_center() {
    local current_window
    current_window=$(tmux display-message -p '#{window_name}' 2>/dev/null)
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

    if in_command_center; then
        # In command center - create window then join to command center
        tmux new-window -n "$branch_name" -c "$working_dir"
        local new_pane_id
        new_pane_id=$(tmux display-message -p '#{pane_id}')

        # Add to state file so it can be restored later
        local session_name
        session_name=$(tmux display-message -p '#{session_name}')
        local state_file="$PARA_LLM_ROOT/recovery/command-center-state-${session_name}"
        echo "$new_pane_id|$branch_name|new|$project_name" >> "$state_file"

        # Join pane to command center
        tmux join-pane -s "$new_pane_id" -t "$COMMAND_CENTER" -h

        # Reapply tiled layout
        tmux select-layout -t "$COMMAND_CENTER" tiled

        # Initialize pane display option
        tmux set-option -p -t "$new_pane_id" @pane_display "#[fg=green]No Claude | $project_name | $branch_name#[default]" 2>/dev/null || true

        # Start state monitor for the new pane
        local monitor_script
        monitor_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugins/claude-state-monitor/state-detector.sh"
        if [[ -x "$monitor_script" ]]; then
            nohup "$monitor_script" "$new_pane_id" "$project_name" "$branch_name" </dev/null >/dev/null 2>&1 &
        fi

        # Switch to command center and select the new pane
        tmux select-window -t "$COMMAND_CENTER"
    else
        # Normal mode - just create window
        tmux new-window -n "$branch_name" -c "$working_dir"
    fi
}

# Create CLAUDE.md for multi-repo environments
# Usage: create_multi_repo_claude_md "/path/to/env" "branch-name" "repo1" "repo2" ...
create_multi_repo_claude_md() {
    local env_dir="$1"
    local branch_name="$2"
    shift 2
    local repos=("$@")

    cat > "$env_dir/CLAUDE.md" << 'CLAUDE_MD_EOF'
# Multi-Repository Environment

This change affects multiple repositories that need to stay synchronized.

## Repositories

CLAUDE_MD_EOF

    # List the repos
    for repo in "${repos[@]}"; do
        echo "- \`$repo/\`" >> "$env_dir/CLAUDE.md"
    done

    cat >> "$env_dir/CLAUDE.md" << 'CLAUDE_MD_EOF'

## Best Practices for Multi-Repo Changes

### Commit Messages
- Use the same commit message prefix across all repos (e.g., `[feature-x]` or the branch name)
- Reference related commits in other repos when relevant

### PR Titles & Descriptions
- Use consistent PR titles across repos
- In each PR description, link to the related PRs in other repos
- Example: "Related: org/other-repo#123"

### Documentation
- Update README/docs in each repo to reflect cross-repo dependencies
- If adding shared interfaces or contracts, document them in both repos

### Testing
- Test the integration between repos before merging any individual PR
- Consider which repo's changes should merge first (dependency order)

### Merging Strategy
- Coordinate merge timing to minimize broken states
- If repos depend on each other, merge the dependency first
- Consider using feature flags if changes can't be deployed atomically
CLAUDE_MD_EOF
}

# Find git repos in ~/code (base repos only - directories with .git dir at top level)
# Returns newline-separated list of selected repos (supports multi-select)
select_repo() {
    {
        echo "← Back"
        echo "⚡ Plain terminal (no project)"
        find "$CODE_DIR" -maxdepth 2 -name ".git" -type d 2>/dev/null | \
            xargs -I {} dirname {} | \
            grep "^${CODE_DIR}/[^/]*$" | \
            sed "s|${CODE_DIR}/||" | \
            sort -u
    } | fzf --prompt="Select project(s) [Tab=select, Enter=confirm]: " --height=40% --reverse --multi
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
            while read -r branch; do
                # Exclude branches that already have local clones
                if [[ ! -d "$ENVS_DIR/${project}-${branch}" ]]; then
                    echo "$branch"
                fi
            done
    } | fzf --prompt="Select remote branch: " --height=40% --reverse
}

# Find existing multi-repo environments containing all the selected repos
select_existing_multi_repo_clone() {
    local repos=("$@")
    {
        echo "← Back"
        for dir in "$ENVS_DIR"/*/; do
            if [[ -d "$dir" ]]; then
                local all_found=true
                for repo in "${repos[@]}"; do
                    if [[ ! -d "${dir}${repo}" ]]; then
                        all_found=false
                        break
                    fi
                done
                if [[ "$all_found" == true ]]; then
                    basename "$dir"
                fi
            fi
        done 2>/dev/null | sort
    } | fzf --prompt="Select environment: " --height=40% --reverse
}

select_resume_or_new() {
    printf "← Back\nResume - continue existing local clone\nAttach - checkout existing remote branch\nNew - create a new feature branch" | \
        fzf --prompt="What would you like to do? " --height=16% --reverse
}

# Main flow with back button support
main() {
    local step=1
    local REPO_NAMES=()  # Array of selected repos (supports multi-select)
    local IS_MULTI_REPO=false
    local REPO_COUNT=1
    local PROJECT_NAME=""

    while true; do
        case $step in
            1)
                # Step 1: Select project(s) - supports multi-select
                local repo_selection
                repo_selection=$(select_repo)
                if [[ -z "$repo_selection" ]]; then
                    exit 0
                fi

                # Parse multi-select result into array
                REPO_NAMES=()
                while IFS= read -r line; do
                    [[ -n "$line" ]] && REPO_NAMES+=("$line")
                done <<< "$repo_selection"

                # Handle special options (only valid as single selection)
                if [[ "${#REPO_NAMES[@]}" -eq 1 ]]; then
                    if [[ "${REPO_NAMES[0]}" == "← Back" ]]; then
                        exit 0  # Can't go back from first step
                    elif [[ "${REPO_NAMES[0]}" == "⚡ Plain terminal (no project)" ]]; then
                        # Open bare shell in CODE_DIR at end of window list
                        if in_command_center; then
                            create_feature_window "terminal" "$CODE_DIR"
                        else
                            # Get last index before creating the window
                            local last_idx
                            last_idx=$(tmux list-windows -F '#{window_index}' | sort -n | tail -1)
                            # Create window then move to end if not already there
                            tmux new-window -n "terminal" -c "$CODE_DIR"
                            local cur_idx
                            cur_idx=$(tmux display-message -p '#{window_index}')
                            if [[ "$cur_idx" -le "$last_idx" ]]; then
                                tmux move-window -t ":$((last_idx + 1))"
                            fi
                        fi
                        exit 0
                    fi
                fi

                # Filter out any special options if mixed with real repos
                local filtered_repos=()
                for repo in "${REPO_NAMES[@]}"; do
                    if [[ "$repo" != "← Back" && "$repo" != "⚡ Plain terminal (no project)" ]]; then
                        filtered_repos+=("$repo")
                    fi
                done
                REPO_NAMES=("${filtered_repos[@]}")

                if [[ "${#REPO_NAMES[@]}" -eq 0 ]]; then
                    exit 0
                fi

                # For multi-repo, prompt for a project name
                if [[ "${#REPO_NAMES[@]}" -gt 1 ]]; then
                    IS_MULTI_REPO=true
                    REPO_COUNT="${#REPO_NAMES[@]}"
                    echo "Selected ${REPO_COUNT} repositories:"
                    for repo in "${REPO_NAMES[@]}"; do
                        echo "  - $repo"
                    done
                    echo ""
                    # Use first repo for git operations (branch listing, etc.)
                    REPO_ROOT="${CODE_DIR}/${REPO_NAMES[0]}"
                else
                    IS_MULTI_REPO=false
                    REPO_COUNT=1
                    PROJECT_NAME=""
                    # Single repo - use repo name as before
                    REPO_NAME="${REPO_NAMES[0]}"
                    REPO_ROOT="${CODE_DIR}/${REPO_NAME}"
                fi
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
                if [[ "$IS_MULTI_REPO" == true ]]; then
                    # Multi-repo: find environments containing all selected repos
                    local selected_env
                    selected_env=$(select_existing_multi_repo_clone "${REPO_NAMES[@]}")
                    if [[ -z "$selected_env" ]]; then
                        exit 0
                    elif [[ "$selected_env" == "← Back" ]]; then
                        step=2
                        continue
                    fi

                    ENV_DIR="${ENVS_DIR}/${selected_env}"
                    PROJECT_NAME="$selected_env"
                    local window_name="${PROJECT_NAME} multi-repo (${REPO_COUNT})"
                    create_feature_window "$window_name" "$ENV_DIR"
                    tmux send-keys "claude --dangerously-skip-permissions --resume" Enter
                    exit 0
                else
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
                fi
                ;;
            3c)
                # Step 3c: Select existing remote branch to attach to
                if [[ "$IS_MULTI_REPO" == true ]]; then
                    # Multi-repo: use first repo for branch listing, no project name filter
                    BRANCH_NAME=$(select_remote_branch "$REPO_ROOT" "__multi_repo_no_filter__")
                else
                    BRANCH_NAME=$(select_remote_branch "$REPO_ROOT" "$REPO_NAME")
                fi
                if [[ -z "$BRANCH_NAME" ]]; then
                    exit 0
                elif [[ "$BRANCH_NAME" == "← Back" ]]; then
                    step=2
                    continue
                fi

                if [[ "$IS_MULTI_REPO" == true ]]; then
                    PROJECT_NAME="$BRANCH_NAME"
                    ENV_DIR="${ENVS_DIR}/${BRANCH_NAME}"
                else
                    ENV_DIR="${ENVS_DIR}/${REPO_NAME}-${BRANCH_NAME}"
                fi

                # Create env directory
                mkdir -p "$ENV_DIR"

                # Clone all selected repos
                local primary_clone_dir=""
                for repo in "${REPO_NAMES[@]}"; do
                    local repo_root="${CODE_DIR}/${repo}"
                    local clone_dir="${ENV_DIR}/${repo}"

                    # Get the remote URL from the original repo
                    local remote_url
                    remote_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null)

                    if [[ -z "$remote_url" ]]; then
                        echo "No remote 'origin' found in $repo_root"
                        echo "Press enter to close."
                        read -r
                        rm -rf "$ENV_DIR"
                        exit 1
                    fi

                    echo "Cloning $repo..."
                    if ! git clone "$remote_url" "$clone_dir" 2>&1; then
                        echo "Failed to clone $repo. Press enter to close."
                        read -r
                        rm -rf "$ENV_DIR"
                        exit 1
                    fi

                    git -C "$clone_dir" checkout "$BRANCH_NAME" 2>&1

                    # Track the first repo's clone dir (used for single-repo mode)
                    if [[ -z "$primary_clone_dir" ]]; then
                        primary_clone_dir="$clone_dir"
                    fi
                done

                # For multi-repo, start in env root; for single repo, start in the repo
                if [[ "$IS_MULTI_REPO" == true ]]; then
                    # Create CLAUDE.md explaining multi-repo context
                    create_multi_repo_claude_md "$ENV_DIR" "$BRANCH_NAME" "${REPO_NAMES[@]}"
                    local window_name="${PROJECT_NAME} multi-repo (${REPO_COUNT})"
                    create_feature_window "$window_name" "$ENV_DIR"
                    tmux send-keys "claude --dangerously-skip-permissions" Enter
                else
                    CLONE_DIR="$primary_clone_dir"
                    create_feature_window "$BRANCH_NAME" "$CLONE_DIR"
                    if [[ -f "$CLONE_DIR/paraLlm_setup.sh" ]]; then
                        tmux send-keys "./paraLlm_setup.sh && claude --dangerously-skip-permissions" Enter
                    else
                        tmux send-keys "claude --dangerously-skip-permissions" Enter
                    fi
                fi
                exit 0
                ;;
            3b)
                # Step 3b: Enter new branch/project name
                if [[ "$IS_MULTI_REPO" == true ]]; then
                    echo -n "Project name (or 'back'): "
                else
                    echo -n "New branch/feature name (or 'back'): "
                fi
                read -r INPUT_NAME

                if [[ -z "$INPUT_NAME" ]]; then
                    exit 0
                elif [[ "$INPUT_NAME" == "back" ]]; then
                    step=2
                    continue
                fi

                if [[ "$IS_MULTI_REPO" == true ]]; then
                    # Multi-repo: project name is used as branch name
                    PROJECT_NAME="$INPUT_NAME"
                    BRANCH_NAME="$INPUT_NAME"
                    REPO_NAME="$INPUT_NAME"
                    ENV_DIR="${ENVS_DIR}/${PROJECT_NAME}"
                else
                    BRANCH_NAME="$INPUT_NAME"
                    ENV_DIR="${ENVS_DIR}/${REPO_NAME}-${BRANCH_NAME}"
                fi

                # Check if env already exists
                if [[ -d "$ENV_DIR" ]]; then
                    echo "Directory already exists at $ENV_DIR"
                    echo "Opening existing clone..."
                    sleep 1
                    if [[ "$IS_MULTI_REPO" == true ]]; then
                        local window_name="${PROJECT_NAME} multi-repo (${REPO_COUNT})"
                        create_feature_window "$window_name" "$ENV_DIR"
                        tmux send-keys "claude --dangerously-skip-permissions --resume" Enter
                    else
                        CLONE_DIR="${ENV_DIR}/${REPO_NAME}"
                        create_feature_window "$BRANCH_NAME" "$CLONE_DIR"
                        if [[ -f "$CLONE_DIR/paraLlm_setup.sh" ]]; then
                            tmux send-keys "./paraLlm_setup.sh && claude --dangerously-skip-permissions --resume" Enter
                        else
                            tmux send-keys "claude --dangerously-skip-permissions --resume" Enter
                        fi
                    fi
                    exit 0
                fi

                # Create env directory
                mkdir -p "$ENV_DIR"

                # Clone all selected repos
                local primary_clone_dir=""
                for repo in "${REPO_NAMES[@]}"; do
                    local repo_root="${CODE_DIR}/${repo}"
                    local clone_dir="${ENV_DIR}/${repo}"

                    # Get the remote URL from the original repo
                    local remote_url
                    remote_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null)

                    if [[ -z "$remote_url" ]]; then
                        echo "No remote 'origin' found in $repo_root"
                        echo "Press enter to close."
                        read -r
                        rm -rf "$ENV_DIR"
                        exit 1
                    fi

                    echo "Cloning $repo..."
                    if ! git clone "$remote_url" "$clone_dir" 2>&1; then
                        echo "Failed to clone $repo. Press enter to close."
                        read -r
                        rm -rf "$ENV_DIR"
                        exit 1
                    fi

                    # Check if branch exists on remote
                    if git -C "$clone_dir" show-ref --verify --quiet "refs/remotes/origin/${BRANCH_NAME}"; then
                        # Branch exists on remote, check it out
                        git -C "$clone_dir" checkout "$BRANCH_NAME" 2>&1
                    else
                        # Branch doesn't exist, create new branch
                        git -C "$clone_dir" checkout -b "$BRANCH_NAME" 2>&1
                    fi

                    # Track the first repo's clone dir (used for single-repo mode)
                    if [[ -z "$primary_clone_dir" ]]; then
                        primary_clone_dir="$clone_dir"
                    fi
                done

                # For multi-repo, start in env root; for single repo, start in the repo
                if [[ "$IS_MULTI_REPO" == true ]]; then
                    # Create CLAUDE.md explaining multi-repo context
                    create_multi_repo_claude_md "$ENV_DIR" "$BRANCH_NAME" "${REPO_NAMES[@]}"
                    local window_name="${PROJECT_NAME} multi-repo (${REPO_COUNT})"
                    create_feature_window "$window_name" "$ENV_DIR"
                    tmux send-keys "claude --dangerously-skip-permissions" Enter
                else
                    CLONE_DIR="$primary_clone_dir"
                    create_feature_window "$BRANCH_NAME" "$CLONE_DIR"
                    if [[ -f "$CLONE_DIR/paraLlm_setup.sh" ]]; then
                        tmux send-keys "./paraLlm_setup.sh && claude --dangerously-skip-permissions" Enter
                    else
                        tmux send-keys "claude --dangerously-skip-permissions" Enter
                    fi
                fi
                exit 0
                ;;
        esac
    done
}

main
