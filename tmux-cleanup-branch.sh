#!/usr/bin/env bash

set -u

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
                # Check for unpushed / unverifiable / uncommitted work in ALL repos.
                # Any of these means deleting the env would lose work, so all three
                # gate the rm -rf via the extra force confirmation below.
                local total_unpushed=0
                local repos_with_unpushed=""
                local repos_no_upstream=""
                local repos_dirty=""
                local needs_force=false
                for clone_dir in "$ENV_DIR"/*/; do
                    if [[ -d "$clone_dir/.git" ]]; then
                        # No upstream (e.g. a fresh branch never pushed): we CANNOT
                        # verify pushed state. `git log @{u}..` errors here and was
                        # silenced to 0 — do not treat that as "nothing to lose".
                        if ! git -C "$clone_dir" rev-parse '@{u}' >/dev/null 2>&1; then
                            repos_no_upstream+="  - $(basename "$clone_dir"): no upstream (cannot verify pushed state)\n"
                            needs_force=true
                        else
                            local unpushed
                            unpushed=$(git -C "$clone_dir" log --oneline @{u}.. 2>/dev/null | wc -l | tr -d ' ')
                            if [[ "$unpushed" -gt 0 ]]; then
                                total_unpushed=$((total_unpushed + unpushed))
                                repos_with_unpushed+="  - $(basename "$clone_dir"): $unpushed commit(s)\n"
                                needs_force=true
                            fi
                        fi
                        # Uncommitted / untracked changes are also unrecoverable once deleted.
                        if [[ -n "$(git -C "$clone_dir" status --porcelain 2>/dev/null)" ]]; then
                            repos_dirty+="  - $(basename "$clone_dir"): uncommitted/untracked changes\n"
                            needs_force=true
                        fi
                    fi
                done

                if [[ "$needs_force" == true ]]; then
                    echo "WARNING: this environment may contain work that would be lost!"
                    if [[ -n "$repos_with_unpushed" ]]; then
                        echo "Unpushed commits:"
                        echo -e "$repos_with_unpushed"
                    fi
                    if [[ -n "$repos_no_upstream" ]]; then
                        echo "Branch has no upstream; cannot verify pushed state:"
                        echo -e "$repos_no_upstream"
                    fi
                    if [[ -n "$repos_dirty" ]]; then
                        echo "Uncommitted or untracked changes:"
                        echo -e "$repos_dirty"
                    fi
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

                # Extract branch name from env name (everything after first dash)
                BRANCH_NAME="${ENV_NAME#*-}"

                # Run teardown hook in each repo if it exists
                for clone_dir in "$ENV_DIR"/*/; do
                    if [[ -f "$clone_dir/paraLlm_teardown.sh" ]]; then
                        echo "Running teardown hook in $(basename "$clone_dir")..."
                        (cd "$clone_dir" && ./paraLlm_teardown.sh)
                    fi
                done

                # Kill any tmux windows/panes with this branch name
                if in_command_center; then
                    # In command center: find and kill the pane for this branch
                    local pane_killed=false

                    # Method 1: Look up pane by checking the state file
                    SESSION_NAME=$(tmux display-message -p '#{session_name}')
                    # Resolve the state file via the SAME logic the writer uses
                    # (tmux-command-center.sh / tmux-new-branch.sh): the persistent
                    # recovery dir when installed, /tmp only as the uninstalled
                    # fallback. Reading /tmp unconditionally made Method 1 always
                    # no-op and forced the buggy path-prefix match to run.
                    if [[ -f "$HOME/.para-llm-root" ]]; then
                        STATE_FILE="$PARA_LLM_ROOT/recovery/command-center-state-${SESSION_NAME}"
                    else
                        STATE_FILE="/tmp/tmux-command-center-state-${SESSION_NAME}"
                    fi
                    if [[ -f "$STATE_FILE" ]]; then
                        local pane_to_kill
                        pane_to_kill=$(grep "|${BRANCH_NAME}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f1 | head -1)
                        if [[ -n "$pane_to_kill" ]] && tmux kill-pane -t "$pane_to_kill" 2>/dev/null; then
                            pane_killed=true
                        fi
                    fi

                    # Method 2: Find pane by working directory (fallback)
                    if [[ "$pane_killed" == false ]]; then
                        local pane_id
                        while IFS= read -r line; do
                            pane_id=$(echo "$line" | cut -d: -f1)
                            local pane_path
                            pane_path=$(echo "$line" | cut -d: -f2-)
                            # Check if pane's working dir is inside our env dir.
                            # Require a real path boundary so ".../proj-a" does not
                            # match ".../proj-a-b/..." (a different env's pane).
                            if [[ "$pane_path" == "$ENV_DIR" || "$pane_path" == "$ENV_DIR"/* ]]; then
                                tmux kill-pane -t "$pane_id" 2>/dev/null && pane_killed=true
                            fi
                        done < <(tmux list-panes -t "$COMMAND_CENTER" -F '#{pane_id}:#{pane_current_path}' 2>/dev/null)
                    fi

                    # Reapply layout if we killed a pane
                    if [[ "$pane_killed" == true ]]; then
                        tmux select-layout -t "$COMMAND_CENTER" tiled 2>/dev/null
                    fi
                else
                    # Normal mode: kill windows by name (current session only)
                    local current_window_name
                    current_window_name=$(tmux display-message -p '#{window_name}' 2>/dev/null)
                    # Exact-match window names (no regex/suffix grep, which could
                    # kill unrelated windows or break on metachars in the name).
                    local win_idx win_name
                    while IFS='|' read -r win_idx win_name; do
                        if [[ "$win_name" == "$BRANCH_NAME" ]]; then
                            tmux kill-window -t ":${win_idx}" 2>/dev/null
                        fi
                    done < <(tmux list-windows -F '#{window_index}|#{window_name}' 2>/dev/null)
                    # Only kill current window if it was the feature window
                    if [[ "$current_window_name" == "$BRANCH_NAME" ]]; then
                        safe_kill_window
                    fi
                fi

                # Delete the environment
                echo "Deleting $ENV_DIR..."
                if rm -rf "$ENV_DIR"; then
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
