#!/usr/bin/env bash
# para-llm-restore.sh - Re-launch Claude in restored panes
# Idempotent: checks that pane is idle before launching

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    tmux display-message "para-llm: No bootstrap file found at $BOOTSTRAP_FILE"
    exit 1
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
ENVS_DIR="$PARA_LLM_ROOT/envs"

STATE_FILE="$PARA_LLM_ROOT/recovery/session-state"
LOG_FILE="$PARA_LLM_ROOT/recovery/restore.log"

if [[ ! -f "$STATE_FILE" ]]; then
    tmux display-message "para-llm: No recovery state found"
    exit 0
fi

# Start logging
{
    echo "=== Restore started: $(date -u +"%Y-%m-%dT%H:%M:%S") ==="
} >> "$LOG_FILE"

# Read saved state entries (skip comments and header)
declare -A SAVED_ENTRIES
while IFS='|' read -r win_name pane_path project branch had_claude; do
    # Skip comments and header
    [[ "$win_name" =~ ^# ]] && continue
    [[ "$win_name" == "window_name" ]] && continue
    [[ "$had_claude" == "true" ]] || continue

    SAVED_ENTRIES["$pane_path"]="$project|$branch"
done < "$STATE_FILE"

if [[ ${#SAVED_ENTRIES[@]} -eq 0 ]]; then
    echo "  No Claude sessions to restore" >> "$LOG_FILE"
    tmux display-message "para-llm: No Claude sessions to restore"
    exit 0
fi

# Get current pane information
RESTORED=0
SKIPPED=0

# Directories for pane mapping (used by hooks for real-time updates)
PANE_MAPPING_DIR="/tmp/claude-pane-mapping"
DISPLAY_DIR="$PARA_LLM_ROOT/recovery/pane-display"
mkdir -p "$PANE_MAPPING_DIR/by-cwd" "$DISPLAY_DIR"

while IFS='|' read -r pane_id pane_path pane_pid; do
    # Check if this pane matches a saved entry
    if [[ -n "${SAVED_ENTRIES[$pane_path]:-}" ]]; then
        IFS='|' read -r project branch <<< "${SAVED_ENTRIES[$pane_path]}"

        # Check directory still exists
        if [[ ! -d "$pane_path" ]]; then
            echo "  SKIP $project/$branch: directory no longer exists" >> "$LOG_FILE"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Check pane is idle (no child processes running)
        if pgrep -P "$pane_pid" >/dev/null 2>&1; then
            echo "  SKIP $project/$branch: pane has running processes" >> "$LOG_FILE"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Set up pane mapping for this pane (so hooks can update it later)
        CWD_SAFE=$(echo "$pane_path" | sed 's|/|_|g' | sed 's|^_||')
        MAPPING_FILE="$PANE_MAPPING_DIR/by-cwd/$CWD_SAFE"
        cat > "$MAPPING_FILE" << MAPPING_EOF
PANE_ID=$pane_id
PROJECT=$project
BRANCH=$branch
CWD=$pane_path
MAPPING_EOF

        # Set initial pane title (will show "Starting..." until Claude hooks update it)
        SAFE_PANE_ID="${pane_id//\%/}"
        echo "#[fg=yellow]Working | $project | $branch#[default]" > "$DISPLAY_DIR/$SAFE_PANE_ID"

        # Set initial border color to yellow (starting)
        tmux set-option -p -t "$pane_id" pane-border-style "fg=yellow" 2>/dev/null || true

        # Determine launch command
        SETUP_SCRIPT="$pane_path/paraLlm_setup.sh"
        if [[ -f "$SETUP_SCRIPT" ]]; then
            LAUNCH_CMD="./paraLlm_setup.sh && claude --dangerously-skip-permissions --resume"
        else
            LAUNCH_CMD="claude --dangerously-skip-permissions --resume"
        fi

        # Send command to the pane
        tmux send-keys -t "$pane_id" "$LAUNCH_CMD" Enter
        echo "  RESTORED $project/$branch in $pane_id" >> "$LOG_FILE"
        RESTORED=$((RESTORED + 1))

        # Brief pause between launches to avoid overwhelming
        sleep 0.5
    fi
done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_path}|#{pane_pid}' 2>/dev/null)

echo "  Summary: restored=$RESTORED skipped=$SKIPPED" >> "$LOG_FILE"
tmux display-message "para-llm: Restored $RESTORED Claude session(s), skipped $SKIPPED"
