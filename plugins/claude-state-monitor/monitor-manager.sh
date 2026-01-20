#!/bin/bash

# Claude State Monitor Manager
# Manages state-detector processes for Command Center panes
#
# Usage:
#   monitor-manager.sh attach [window_name]   - Start monitors for all panes
#   monitor-manager.sh detach [window_name]   - Stop all monitors
#   monitor-manager.sh status [window_name]   - Show monitor status

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR_SCRIPT="$SCRIPT_DIR/state-detector.sh"
DEFAULT_WINDOW="command-center"
DISPLAY_DIR="/tmp/claude-pane-display"
PID_DIR="/tmp/claude-state-monitor-pids"

# Get session name for state file lookup
get_session_name() {
    tmux display-message -p '#{session_name}' 2>/dev/null
}

# Get pane info from command center state file
# Returns: project|branch for given pane_id
get_pane_info() {
    local pane_id="$1"
    local pane_path="$2"
    local session_name
    session_name=$(get_session_name)
    local state_file="/tmp/tmux-command-center-state-${session_name}"

    # Try to find in state file first
    if [[ -f "$state_file" ]]; then
        local line
        line=$(grep "^${pane_id}|" "$state_file" 2>/dev/null)
        if [[ -n "$line" ]]; then
            local branch project
            branch=$(echo "$line" | cut -d'|' -f2)
            project=$(echo "$line" | cut -d'|' -f4)
            echo "${project}|${branch}"
            return
        fi
    fi

    # Fallback: derive from path
    local project branch
    project=$(basename "$pane_path")
    local parent_dir
    parent_dir=$(basename "$(dirname "$pane_path")")
    if [[ "$parent_dir" == *"-"* ]]; then
        branch="${parent_dir#*-}"
    else
        branch="$parent_dir"
    fi
    echo "${project}|${branch}"
}

# Check if window exists
window_exists() {
    local window_name="$1"
    tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qx "$window_name"
}

# Attach monitors to all panes in a window
cmd_attach() {
    local window_name="${1:-$DEFAULT_WINDOW}"

    if ! window_exists "$window_name"; then
        echo "Error: Window '$window_name' does not exist" >&2
        exit 1
    fi

    # Ensure directories exist
    mkdir -p "$DISPLAY_DIR" "$PID_DIR"

    # First, kill any existing monitors
    cmd_detach "$window_name" 2>/dev/null || true

    local attached=0

    # Get all panes in the window
    while IFS='|' read -r pane_id pane_path; do
        [[ -z "$pane_id" ]] && continue

        # Get project and branch info
        local pane_info project branch
        pane_info=$(get_pane_info "$pane_id" "$pane_path")
        project=$(echo "$pane_info" | cut -d'|' -f1)
        branch=$(echo "$pane_info" | cut -d'|' -f2)

        # Start state-detector as fully detached background process
        # Use nohup + redirect to fully detach from parent
        local safe_id="${pane_id//\%/}"
        nohup "$DETECTOR_SCRIPT" "$pane_id" "$project" "$branch" </dev/null >/dev/null 2>&1 &
        local pid=$!

        # Save PID for later cleanup
        echo "$pid" > "$PID_DIR/$safe_id.pid"

        ((attached++))
        echo "Attached monitor to pane $pane_id ($project | $branch) [PID: $pid]"
    done < <(tmux list-panes -t "$window_name" -F '#{pane_id}|#{pane_current_path}' 2>/dev/null)

    echo "Attached $attached monitors"
}

# Detach monitors from all panes in a window
cmd_detach() {
    local window_name="${1:-$DEFAULT_WINDOW}"

    local detached=0

    # Kill all state-detector processes we started
    if [[ -d "$PID_DIR" ]]; then
        for pid_file in "$PID_DIR"/*.pid; do
            [[ -f "$pid_file" ]] || continue

            local pid safe_id
            pid=$(cat "$pid_file" 2>/dev/null)
            safe_id=$(basename "$pid_file" .pid)

            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                ((detached++))
            fi

            rm -f "$pid_file"

            # Clean up display file
            rm -f "$DISPLAY_DIR/$safe_id" 2>/dev/null
        done
    fi

    # Also kill any orphaned state-detector processes
    pkill -f "state-detector.sh" 2>/dev/null || true

    echo "Detached $detached monitors"
}

# Show status of monitors
cmd_status() {
    local window_name="${1:-$DEFAULT_WINDOW}"

    if ! window_exists "$window_name"; then
        echo "Window '$window_name' does not exist"
        return 1
    fi

    echo "Monitor status for window: $window_name"
    echo "---"

    while IFS='|' read -r pane_id pane_path; do
        [[ -z "$pane_id" ]] && continue

        local safe_id="${pane_id//\%/}"
        local display_file="$DISPLAY_DIR/$safe_id"
        local pid_file="$PID_DIR/$safe_id.pid"
        local display_status="(no display file)"
        local monitor_status="not running"

        if [[ -f "$display_file" ]]; then
            display_status=$(cat "$display_file")
        fi

        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file" 2>/dev/null)
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                monitor_status="running (PID: $pid)"
            else
                monitor_status="dead (stale PID file)"
            fi
        fi

        echo "Pane $pane_id: $monitor_status"
        echo "  Display: $display_status"
    done < <(tmux list-panes -t "$window_name" -F '#{pane_id}|#{pane_current_path}' 2>/dev/null)
}

# Main
case "${1:-}" in
    attach)
        cmd_attach "${2:-}"
        ;;
    detach)
        cmd_detach "${2:-}"
        ;;
    status)
        cmd_status "${2:-}"
        ;;
    *)
        echo "Usage: $0 {attach|detach|status} [window_name]"
        echo ""
        echo "Commands:"
        echo "  attach [window]  - Start state monitors for all panes in window"
        echo "  detach [window]  - Stop all monitors for window"
        echo "  status [window]  - Show monitor status for window"
        echo ""
        echo "Default window: $DEFAULT_WINDOW"
        exit 1
        ;;
esac
