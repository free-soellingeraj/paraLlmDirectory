#!/usr/bin/env bash
# remote-restore-full.sh - Full orchestrator for remote restore
# 1. Pulls state from remote (if not already pulled)
# 2. For each entry: git clone from git_remote
# 3. git checkout branch
# 4. Creates tmux window
# 5. Launches Claude with --dangerously-skip-permissions --resume if it was running

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    echo "para-llm: No bootstrap file found"
    exit 1
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"

# Source config
if [[ -f "$PARA_LLM_ROOT/config" ]]; then
    source "$PARA_LLM_ROOT/config"
fi

ENVS_DIR="$PARA_LLM_ROOT/envs"
STATE_FILE="$PARA_LLM_ROOT/recovery/session-state"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$PARA_LLM_ROOT/recovery/remote-restore.log"

mkdir -p "$ENVS_DIR"

# Pull from remote first if state file doesn't exist
if [[ ! -f "$STATE_FILE" ]]; then
    echo "No local state found. Pulling from remote..."
    "$SCRIPT_DIR/remote-pull.sh" || exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No session state available after pull."
    exit 1
fi

{
    echo "=== Remote restore started: $(date -u +"%Y-%m-%dT%H:%M:%S") ==="
} >> "$LOG_FILE"

# Process each entry
RESTORED=0
SKIPPED=0
FAILED=0

while IFS='|' read -r win_name pane_path project branch had_claude git_remote; do
    # Skip comments and header
    [[ "$win_name" =~ ^# ]] && continue
    [[ "$win_name" == "window_name" ]] && continue

    echo ""
    echo "Processing: $project/$branch"

    # Determine env directory
    ENV_NAME="${project}-${branch}"
    ENV_DIR="$ENVS_DIR/$ENV_NAME"
    PROJECT_DIR="$ENV_DIR/$project"

    # Clone if directory doesn't exist
    if [[ ! -d "$PROJECT_DIR" ]]; then
        if [[ -z "$git_remote" ]]; then
            echo "  SKIP: No git remote URL for $project/$branch"
            echo "  SKIP $project/$branch: no git_remote" >> "$LOG_FILE"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        echo "  Cloning from $git_remote..."
        mkdir -p "$ENV_DIR"
        if ! git clone "$git_remote" "$PROJECT_DIR" 2>&1; then
            echo "  FAILED: Clone failed for $project/$branch"
            echo "  FAILED $project/$branch: clone failed" >> "$LOG_FILE"
            FAILED=$((FAILED + 1))
            continue
        fi

        # Checkout branch
        if [[ "$branch" != "main" && "$branch" != "master" ]]; then
            echo "  Checking out branch: $branch"
            if ! git -C "$PROJECT_DIR" checkout "$branch" 2>&1; then
                # Try fetching and checking out as remote tracking branch
                git -C "$PROJECT_DIR" fetch origin "$branch" 2>/dev/null
                if ! git -C "$PROJECT_DIR" checkout -b "$branch" "origin/$branch" 2>&1; then
                    echo "  WARNING: Could not checkout branch $branch, staying on default"
                    echo "  WARN $project/$branch: branch checkout failed" >> "$LOG_FILE"
                fi
            fi
        fi

        # Run setup script if present
        SETUP_SCRIPT="$PROJECT_DIR/paraLlm_setup.sh"
        if [[ -f "$SETUP_SCRIPT" && -x "$SETUP_SCRIPT" ]]; then
            echo "  Running setup script..."
            (cd "$PROJECT_DIR" && ./paraLlm_setup.sh) 2>&1 || true
        fi
    else
        echo "  Directory already exists, skipping clone."
    fi

    # Create tmux window
    echo "  Creating tmux window: $win_name"
    tmux new-window -n "$win_name" -c "$PROJECT_DIR" 2>/dev/null || {
        echo "  FAILED: Could not create tmux window"
        echo "  FAILED $project/$branch: tmux window creation" >> "$LOG_FILE"
        FAILED=$((FAILED + 1))
        continue
    }

    # Launch Claude if it was running
    if [[ "$had_claude" == "true" ]]; then
        echo "  Launching Claude..."
        # Determine launch command
        SETUP_SCRIPT="$PROJECT_DIR/paraLlm_setup.sh"
        if [[ -f "$SETUP_SCRIPT" ]]; then
            LAUNCH_CMD="./paraLlm_setup.sh && claude --dangerously-skip-permissions --resume"
        else
            LAUNCH_CMD="claude --dangerously-skip-permissions --resume"
        fi
        tmux send-keys -t "$win_name" "$LAUNCH_CMD" Enter
    fi

    echo "  RESTORED $project/$branch"
    echo "  RESTORED $project/$branch" >> "$LOG_FILE"
    RESTORED=$((RESTORED + 1))

    # Brief pause between operations
    sleep 0.5
done < "$STATE_FILE"

echo ""
echo "Remote restore complete: restored=$RESTORED skipped=$SKIPPED failed=$FAILED"
echo "  Summary: restored=$RESTORED skipped=$SKIPPED failed=$FAILED" >> "$LOG_FILE"

tmux display-message "para-llm: Remote restored $RESTORED session(s), skipped $SKIPPED, failed $FAILED"
