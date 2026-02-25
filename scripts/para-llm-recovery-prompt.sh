#!/usr/bin/env bash
# para-llm-recovery-prompt.sh - Prompt user to restore saved sessions on tmux start
# Runs via session-created hook

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    exit 0
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"

# Source config for INSTALL_DIR
if [[ -f "$PARA_LLM_ROOT/config" ]]; then
    source "$PARA_LLM_ROOT/config"
fi

STATE_FILE="$PARA_LLM_ROOT/recovery/session-state"
REMOTES_DIR="$PARA_LLM_ROOT/remotes"
ACTIVE_FILE="$REMOTES_DIR/.active"

# Check if a remote is configured
HAS_REMOTE=false
if [[ -f "$ACTIVE_FILE" ]]; then
    ACTIVE_REMOTE=$(cat "$ACTIVE_FILE")
    if [[ -f "$REMOTES_DIR/$ACTIVE_REMOTE" ]]; then
        HAS_REMOTE=true
    fi
fi

# Determine remote restore script path
REMOTE_RESTORE_SCRIPT="${INSTALL_DIR:-}/plugins/remote-save/remote-restore-full.sh"

# If no local state exists
if [[ ! -f "$STATE_FILE" ]]; then
    if [[ "$HAS_REMOTE" == true && -x "$REMOTE_RESTORE_SCRIPT" ]]; then
        # No local state but remote configured - offer remote restore
        tmux display-menu -T "Para-LLM: No local state. Remote '$ACTIVE_REMOTE' available." \
            "Pull & Restore from remote"  "r" "run-shell -b '$REMOTE_RESTORE_SCRIPT'" \
            "Skip"                        "s" ""
    fi
    exit 0
fi

# Parse state file
TIMESTAMP=$(grep "^# saved:" "$STATE_FILE" | sed 's/^# saved: //')
SESSION_COUNT=$(grep -v "^#" "$STATE_FILE" | grep -v "^window_name" | grep "|true|" | wc -l | tr -d ' ')

if [[ "$SESSION_COUNT" -eq 0 ]]; then
    exit 0
fi

# Calculate age of recovery state
if [[ -n "$TIMESTAMP" ]]; then
    # Try to parse the timestamp for display
    SAVED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$TIMESTAMP" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)
    if [[ "$SAVED_EPOCH" -gt 0 ]]; then
        AGE_SECONDS=$((NOW_EPOCH - SAVED_EPOCH))
        AGE_HOURS=$((AGE_SECONDS / 3600))
        if [[ $AGE_HOURS -gt 48 ]]; then
            AGE_WARNING=" (WARNING: ${AGE_HOURS}h old)"
        elif [[ $AGE_HOURS -gt 0 ]]; then
            AGE_DISPLAY="${AGE_HOURS}h ago"
        else
            AGE_MINUTES=$((AGE_SECONDS / 60))
            AGE_DISPLAY="${AGE_MINUTES}m ago"
        fi
    fi
fi

DISPLAY_TIME="${AGE_DISPLAY:-$TIMESTAMP}"
TITLE="Para-LLM Recovery: $SESSION_COUNT session(s) from $DISPLAY_TIME${AGE_WARNING:-}"

# Build menu with optional remote restore
if [[ "$HAS_REMOTE" == true && -x "$REMOTE_RESTORE_SCRIPT" ]]; then
    tmux display-menu -T "$TITLE" \
        "Restore (local)"   "r" "run-shell -b '$PARA_LLM_ROOT/scripts/para-llm-do-restore.sh'" \
        "Restore (remote)"  "R" "run-shell -b '$REMOTE_RESTORE_SCRIPT'" \
        "Discard"           "d" "run-shell -b '$PARA_LLM_ROOT/scripts/para-llm-do-discard.sh'" \
        "Skip"              "s" ""
else
    tmux display-menu -T "$TITLE" \
        "Restore"  "r" "run-shell -b '$PARA_LLM_ROOT/scripts/para-llm-do-restore.sh'" \
        "Discard"  "d" "run-shell -b '$PARA_LLM_ROOT/scripts/para-llm-do-discard.sh'" \
        "Skip"     "s" ""
fi
