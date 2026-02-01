#!/usr/bin/env bash
# para-llm-save-state.sh - Save Claude session state for recovery
# Called by tmux-resurrect's @resurrect-hook-post-save-all (every 1 minute via continuum)

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    exit 0
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
ENVS_DIR="$PARA_LLM_ROOT/envs"

# Ensure recovery directory exists
mkdir -p "$PARA_LLM_ROOT/recovery"

# Exit command center before saving (so restore gets individual windows)
COMMAND_CENTER="command-center"
if tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$COMMAND_CENTER"; then
    # Command center is active - restore it to normal windows first
    "$PARA_LLM_ROOT/scripts/tmux-command-center.sh" 2>/dev/null || true
    # Brief pause to let tmux settle
    sleep 0.2
fi

STATE_FILE="$PARA_LLM_ROOT/recovery/session-state"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S")

# Collect pane information
# Format: session_name|window_name|pane_id|pane_current_path|pane_pid
PANE_DATA=$(tmux list-panes -a -F '#{session_name}|#{window_name}|#{pane_id}|#{pane_current_path}|#{pane_pid}' 2>/dev/null)

if [[ -z "$PANE_DATA" ]]; then
    exit 0
fi

# Get the session name (use first session found)
SESSION_NAME=$(echo "$PANE_DATA" | head -1 | cut -d'|' -f1)

# Build state file
{
    echo "# para-llm recovery state"
    echo "# saved: $TIMESTAMP"
    echo "# session: $SESSION_NAME"
    echo "window_name|pane_path|project|branch|had_claude"

    while IFS='|' read -r sess_name win_name pane_id pane_path pane_pid; do
        # Only process panes whose path is under ENVS_DIR
        if [[ "$pane_path" == "$ENVS_DIR"/* ]]; then
            # Derive project and branch from path
            # Path structure: $ENVS_DIR/<project>-<branch>/<project>/...
            REL_PATH="${pane_path#"$ENVS_DIR"/}"
            ENV_NAME="${REL_PATH%%/*}"

            # Extract project and branch from env name (format: project-branch)
            # Branch could contain hyphens, so we need to find the project name
            # by checking what directory exists inside the env
            ENV_DIR="$ENVS_DIR/$ENV_NAME"
            if [[ -d "$ENV_DIR" ]]; then
                # Find the project directory inside the env
                PROJECT=""
                for dir in "$ENV_DIR"/*/; do
                    if [[ -d "$dir/.git" ]]; then
                        PROJECT=$(basename "$dir")
                        break
                    fi
                done

                if [[ -z "$PROJECT" ]]; then
                    # Fallback: use first directory
                    for dir in "$ENV_DIR"/*/; do
                        PROJECT=$(basename "$dir")
                        break
                    done
                fi

                if [[ -n "$PROJECT" ]]; then
                    # Branch is env_name with project prefix removed
                    BRANCH="${ENV_NAME#"$PROJECT"-}"

                    # Check if Claude is running in this pane
                    HAD_CLAUDE="false"
                    if pgrep -P "$pane_pid" -f "claude" >/dev/null 2>&1; then
                        HAD_CLAUDE="true"
                    fi

                    echo "$win_name|$pane_path|$PROJECT|$BRANCH|$HAD_CLAUDE"
                fi
            fi
        fi
    done <<< "$PANE_DATA"
} > "$STATE_FILE.tmp"

# Only write if we found at least one env pane
ENTRY_COUNT=$(grep -c "^[^#]" "$STATE_FILE.tmp" 2>/dev/null | tail -1)
# Subtract 1 for the header line
ENTRY_COUNT=$((ENTRY_COUNT - 1))

if [[ $ENTRY_COUNT -gt 0 ]]; then
    mv "$STATE_FILE.tmp" "$STATE_FILE"
else
    rm -f "$STATE_FILE.tmp"
fi
