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
DISPLAY_DIR="$PARA_LLM_ROOT/recovery/pane-display"
LOG_FILE="$PARA_LLM_ROOT/recovery/restore.log"

# Read INSTALL_DIR from config (needed to find plugin scripts)
INSTALL_DIR=""
if [[ -f "$PARA_LLM_ROOT/config" ]]; then
    source "$PARA_LLM_ROOT/config"
fi

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

# Check if command-center window exists and re-apply its window options
COMMAND_CENTER="command-center"
HAS_COMMAND_CENTER=false
if tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$COMMAND_CENTER"; then
    HAS_COMMAND_CENTER=true

    if [[ -n "$INSTALL_DIR" ]]; then
        # Re-apply pane border settings (tmux-resurrect doesn't restore window options)
        local_display_helper="$INSTALL_DIR/plugins/claude-state-monitor/get-pane-display.sh"
        if [[ -f "$local_display_helper" ]]; then
            tmux set-window-option -t "$COMMAND_CENTER" pane-border-status top
            tmux set-window-option -t "$COMMAND_CENTER" pane-border-format \
                "#{?pane_active,** , }#{pane_index}: #($local_display_helper #{pane_index})#{?pane_active, **,} "
            echo "  Re-applied command-center window options" >> "$LOG_FILE"
        else
            echo "  WARN: display helper not found at $local_display_helper" >> "$LOG_FILE"
        fi
    else
        echo "  WARN: INSTALL_DIR not set in config, cannot restore command-center display" >> "$LOG_FILE"
    fi
fi

# Ensure display and mapping directories exist
mkdir -p "$DISPLAY_DIR"
mkdir -p "/tmp/claude-pane-mapping/by-cwd"

# Get current pane information
RESTORED=0
SKIPPED=0

while IFS='|' read -r pane_id pane_path pane_pid; do
    # Check if this pane matches a saved entry
    if [[ -n "${SAVED_ENTRIES[$pane_path]}" ]]; then
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

        # Create display file for this pane's new ID
        safe_pane_id="${pane_id//\%/}"
        echo "Starting... | $branch | $project" > "$DISPLAY_DIR/$safe_pane_id"

        # Create pane mapping so state-tracker hooks can find this pane
        cwd_safe=$(echo "$pane_path" | sed 's|/|_|g' | sed 's|^_||')
        cat > "/tmp/claude-pane-mapping/by-cwd/$cwd_safe" << MAPPING_EOF
PANE_ID=$pane_id
PROJECT=$project
BRANCH=$branch
MAPPING_EOF

        # Determine launch command
        SETUP_SCRIPT="$pane_path/paraLlm_setup.sh"
        if [[ -f "$SETUP_SCRIPT" ]]; then
            LAUNCH_CMD="./paraLlm_setup.sh && claude --dangerously-skip-permissions --resume"
        else
            LAUNCH_CMD="claude --dangerously-skip-permissions --resume"
        fi

        # Send command to the pane
        tmux send-keys -t "$pane_id" "$LAUNCH_CMD" Enter
        echo "  RESTORED $project/$branch in $pane_id (display: $safe_pane_id)" >> "$LOG_FILE"
        RESTORED=$((RESTORED + 1))

        # Brief pause between launches to avoid overwhelming
        sleep 0.5
    fi
done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_path}|#{pane_pid}' 2>/dev/null)

echo "  Summary: restored=$RESTORED skipped=$SKIPPED" >> "$LOG_FILE"

# Start state monitor if command-center exists and we restored panes
if [[ "$HAS_COMMAND_CENTER" == true ]] && [[ $RESTORED -gt 0 ]] && [[ -n "$INSTALL_DIR" ]]; then
    MONITOR_PLUGIN="$INSTALL_DIR/plugins/claude-state-monitor/monitor-manager.sh"
    if [[ -x "$MONITOR_PLUGIN" ]]; then
        nohup "$MONITOR_PLUGIN" attach "$COMMAND_CENTER" </dev/null >/dev/null 2>&1 &
        echo "  Started state monitor (PID: $!)" >> "$LOG_FILE"
    elif [[ -f "$MONITOR_PLUGIN" ]]; then
        chmod +x "$MONITOR_PLUGIN" 2>/dev/null
        nohup "$MONITOR_PLUGIN" attach "$COMMAND_CENTER" </dev/null >/dev/null 2>&1 &
        echo "  Started state monitor (PID: $!)" >> "$LOG_FILE"
    else
        echo "  WARN: monitor-manager.sh not found at $MONITOR_PLUGIN" >> "$LOG_FILE"
    fi
fi

tmux display-message "para-llm: Restored $RESTORED Claude session(s), skipped $SKIPPED"
