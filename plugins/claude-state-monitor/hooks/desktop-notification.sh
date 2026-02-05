#!/usr/bin/env bash

# Claude Code Desktop Notification Hook
# Shows macOS desktop notifications when Claude needs attention
#
# Usage: desktop-notification.sh <event_type>
# Event types: idle, permission
#
# Configuration (in $PARA_LLM_ROOT/config):
#   NOTIFICATION_DESKTOP_ENABLED=1|0 (default: 1)
#   NOTIFICATION_DESKTOP_SOUND=1|0 (default: 0, use notification-sound.sh instead)
#   NOTIFICATION_DESKTOP_ONLY_UNFOCUSED=1|0 (default: 1)

set -euo pipefail

EVENT_TYPE="${1:-idle}"

# Read hook input from stdin
INPUT=$(cat)

# Load para-llm-directory config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
fi

# Configuration with defaults (config file values take precedence)
NOTIFY_ENABLED="${NOTIFICATION_DESKTOP_ENABLED:-1}"
NOTIFY_SOUND="${NOTIFICATION_DESKTOP_SOUND:-0}"
ONLY_UNFOCUSED="${NOTIFICATION_DESKTOP_ONLY_UNFOCUSED:-1}"

# Exit early if notifications disabled
if [[ "$NOTIFY_ENABLED" != "1" ]]; then
    exit 0
fi

# Extract info from hook input
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
MESSAGE=$(echo "$INPUT" | jq -r '.message // ""')

# Derive project and branch from CWD
PROJECT=""
BRANCH=""
if [[ -n "$CWD" ]]; then
    # Try to get from pane mapping
    PANE_MAPPING_DIR="/tmp/claude-pane-mapping"
    CWD_SAFE=$(echo "$CWD" | sed 's|/|_|g' | sed 's|^_||')
    MAPPING_FILE="$PANE_MAPPING_DIR/by-cwd/$CWD_SAFE"

    if [[ -f "$MAPPING_FILE" ]]; then
        PANE_ID=$(grep '^PANE_ID=' "$MAPPING_FILE" | cut -d'=' -f2-)
        PROJECT=$(grep '^PROJECT=' "$MAPPING_FILE" | cut -d'=' -f2-)
        BRANCH=$(grep '^BRANCH=' "$MAPPING_FILE" | cut -d'=' -f2-)

        # Check if pane is focused
        if [[ "$ONLY_UNFOCUSED" == "1" && -n "$PANE_ID" ]]; then
            ACTIVE_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
            if [[ "$PANE_ID" == "$ACTIVE_PANE" ]]; then
                # Pane is focused, skip notification
                exit 0
            fi
        fi
    else
        # Fallback: derive from path
        PROJECT=$(basename "$CWD")
        PARENT_DIR=$(basename "$(dirname "$CWD")")
        if [[ "$PARENT_DIR" == *"-"* ]]; then
            BRANCH="${PARENT_DIR#*-}"
        fi
    fi
fi

# Build notification title and message
case "$EVENT_TYPE" in
    idle)
        TITLE="Claude Code Ready"
        if [[ -n "$PROJECT" && -n "$BRANCH" ]]; then
            SUBTITLE="$PROJECT ($BRANCH)"
        elif [[ -n "$PROJECT" ]]; then
            SUBTITLE="$PROJECT"
        else
            SUBTITLE=""
        fi
        BODY="Claude is waiting for your input"
        ;;
    permission)
        TITLE="Claude Code Needs Permission"
        if [[ -n "$PROJECT" && -n "$BRANCH" ]]; then
            SUBTITLE="$PROJECT ($BRANCH)"
        elif [[ -n "$PROJECT" ]]; then
            SUBTITLE="$PROJECT"
        else
            SUBTITLE=""
        fi
        if [[ -n "$MESSAGE" ]]; then
            BODY="$MESSAGE"
        else
            BODY="Claude needs your permission to proceed"
        fi
        ;;
    *)
        TITLE="Claude Code"
        SUBTITLE=""
        BODY="Notification: $EVENT_TYPE"
        ;;
esac

# Build osascript command
# Using osascript for native macOS notifications
SCRIPT="display notification \"$BODY\""

if [[ -n "$SUBTITLE" ]]; then
    SCRIPT="$SCRIPT with title \"$TITLE\" subtitle \"$SUBTITLE\""
else
    SCRIPT="$SCRIPT with title \"$TITLE\""
fi

if [[ "$NOTIFY_SOUND" == "1" ]]; then
    SCRIPT="$SCRIPT sound name \"Glass\""
fi

# Show the notification
osascript -e "$SCRIPT" 2>/dev/null &

exit 0
