#!/bin/bash

# Claude Code Hooks State Tracker
# Called by Claude Code hooks to track operational state
# Writes state to /tmp/claude-state/<session_id>.json
# Also directly updates tmux pane borders for real-time feedback
#
# Usage: state-tracker.sh <event_type>
# Event types: session_start, session_end, pre_tool, post_tool, stop, idle, permission

set -euo pipefail

STATE_DIR="/tmp/claude-state"
PANE_MAPPING_DIR="/tmp/claude-pane-mapping"
DISPLAY_DIR="/tmp/claude-pane-display"
mkdir -p "$STATE_DIR"

EVENT_TYPE="${1:-unknown}"

# Read hook input from stdin
INPUT=$(cat)

# Extract fields from JSON input
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // "default"')
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // ""')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine state based on event type
case "$EVENT_TYPE" in
    session_start)
        STATE="starting"
        DETAIL=""
        ;;
    session_end)
        STATE="ended"
        DETAIL=$(echo "$INPUT" | jq -r '.reason // ""')
        ;;
    pre_tool)
        STATE="working"
        DETAIL="$TOOL_NAME"
        ;;
    post_tool)
        STATE="working"
        DETAIL=""
        ;;
    stop)
        STATE="ready"
        DETAIL=""
        ;;
    idle)
        STATE="ready"
        DETAIL="idle"
        ;;
    permission)
        STATE="blocked"
        DETAIL="Permission"
        ;;
    *)
        STATE="unknown"
        DETAIL=""
        ;;
esac

# Write state to session-specific file
STATE_FILE="$STATE_DIR/$SESSION_ID.json"
cat > "$STATE_FILE" <<EOF
{
  "session_id": "$SESSION_ID",
  "state": "$STATE",
  "detail": "$DETAIL",
  "cwd": "$CWD",
  "tool": "$TOOL_NAME",
  "permission_mode": "$PERMISSION_MODE",
  "event": "$EVENT_TYPE",
  "timestamp": "$TIMESTAMP"
}
EOF

# Also write to a CWD-indexed file for easy lookup by pane path
if [[ -n "$CWD" ]]; then
    # Create sanitized filename from CWD (replace / with _)
    CWD_SAFE=$(echo "$CWD" | sed 's|/|_|g' | sed 's|^_||')
    CWD_FILE="$STATE_DIR/by-cwd/$CWD_SAFE.json"
    mkdir -p "$STATE_DIR/by-cwd"
    cp "$STATE_FILE" "$CWD_FILE"

    # Direct tmux update for real-time feedback
    MAPPING_FILE="$PANE_MAPPING_DIR/by-cwd/$CWD_SAFE"
    if [[ -f "$MAPPING_FILE" ]]; then
        # Read pane mapping
        source "$MAPPING_FILE"

        # Map state to color
        case "$STATE" in
            ready|ended)   COLOR="green" ;;
            blocked)       COLOR="cyan" ;;
            working|starting) COLOR="yellow" ;;
            *)             COLOR="default" ;;
        esac

        # Map state to label
        case "$STATE" in
            ready|ended)   LABEL="Waiting for Input" ;;
            blocked)       LABEL="Needs Action" ;;
            *)             LABEL="Working" ;;
        esac

        # Append detail if present
        if [[ -n "$DETAIL" ]]; then
            LABEL="$LABEL: $DETAIL"
        fi

        # Update tmux border style directly
        if [[ "$COLOR" != "default" ]]; then
            tmux set-option -p -t "$PANE_ID" pane-border-style "fg=$COLOR" 2>/dev/null || true
        else
            tmux set-option -p -t "$PANE_ID" -u pane-border-style 2>/dev/null || true
        fi

        # Write display file for pane-border-format
        DISPLAY_STRING="$LABEL | $PROJECT | $BRANCH"
        SAFE_PANE_ID="${PANE_ID//\%/}"
        mkdir -p "$DISPLAY_DIR"
        echo "$DISPLAY_STRING" > "$DISPLAY_DIR/$SAFE_PANE_ID"
    fi
fi

exit 0
