#!/usr/bin/env bash

# Claude Code Notification Sound Hook
# Plays a sound when Claude finishes its turn or needs attention
#
# Usage: notification-sound.sh <event_type>
# Event types: idle, permission
#
# Configuration (via environment variables):
#   CLAUDE_SOUND_ENABLED=1|0 (default: 1)
#   CLAUDE_SOUND_IDLE=/path/to/sound.aiff (default: system Glass sound)
#   CLAUDE_SOUND_PERMISSION=/path/to/sound.aiff (default: system Sosumi sound)
#   CLAUDE_SOUND_ONLY_UNFOCUSED=1|0 (default: 1, only play if pane not active)

set -euo pipefail

EVENT_TYPE="${1:-idle}"

# Read hook input from stdin (contains notification_type, cwd, etc.)
INPUT=$(cat)

# Configuration with defaults
SOUND_ENABLED="${CLAUDE_SOUND_ENABLED:-1}"
SOUND_IDLE="${CLAUDE_SOUND_IDLE:-/System/Library/Sounds/Glass.aiff}"
SOUND_PERMISSION="${CLAUDE_SOUND_PERMISSION:-/System/Library/Sounds/Sosumi.aiff}"
ONLY_UNFOCUSED="${CLAUDE_SOUND_ONLY_UNFOCUSED:-1}"

# Exit early if sounds disabled
if [[ "$SOUND_ENABLED" != "1" ]]; then
    exit 0
fi

# Check if we should only play when unfocused
if [[ "$ONLY_UNFOCUSED" == "1" ]]; then
    CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

    if [[ -n "$CWD" ]]; then
        # Find the pane for this CWD via the mapping file
        PANE_MAPPING_DIR="/tmp/claude-pane-mapping"
        CWD_SAFE=$(echo "$CWD" | sed 's|/|_|g' | sed 's|^_||')
        MAPPING_FILE="$PANE_MAPPING_DIR/by-cwd/$CWD_SAFE"

        if [[ -f "$MAPPING_FILE" ]]; then
            PANE_ID=$(grep '^PANE_ID=' "$MAPPING_FILE" | cut -d'=' -f2-)

            if [[ -n "$PANE_ID" ]]; then
                # Check if this pane is the active pane in the active window
                ACTIVE_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)

                if [[ "$PANE_ID" == "$ACTIVE_PANE" ]]; then
                    # Pane is focused, skip sound
                    exit 0
                fi
            fi
        fi
    fi
fi

# Select sound based on event type
case "$EVENT_TYPE" in
    idle)
        SOUND_FILE="$SOUND_IDLE"
        ;;
    permission)
        SOUND_FILE="$SOUND_PERMISSION"
        ;;
    *)
        SOUND_FILE="$SOUND_IDLE"
        ;;
esac

# Play the sound (macOS)
if [[ -f "$SOUND_FILE" ]]; then
    # Use afplay in background to not block the hook
    afplay "$SOUND_FILE" &>/dev/null &
fi

exit 0
