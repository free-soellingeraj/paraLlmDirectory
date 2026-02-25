#!/usr/bin/env bash
# remote-save.sh - Push workspace state to active remote
# Called at end of para-llm-save-state.sh (backgrounded, non-blocking)
# Piggybacks on 1-minute tmux-resurrect save cycle

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    exit 0
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"

# Source config
if [[ -f "$PARA_LLM_ROOT/config" ]]; then
    source "$PARA_LLM_ROOT/config"
fi

# Exit if remote save is disabled
if [[ "${REMOTE_SAVE_ENABLED:-1}" != "1" ]]; then
    exit 0
fi

REMOTES_DIR="$PARA_LLM_ROOT/remotes"
ACTIVE_FILE="$REMOTES_DIR/.active"

# Exit if no active remote
if [[ ! -f "$ACTIVE_FILE" ]]; then
    exit 0
fi
ACTIVE_REMOTE=$(cat "$ACTIVE_FILE")
REMOTE_FILE="$REMOTES_DIR/$ACTIVE_REMOTE"
if [[ ! -f "$REMOTE_FILE" ]]; then
    exit 0
fi

# Prevent concurrent runs
LOCK_FILE="/tmp/para-llm-remote-save.lock"
if [[ -f "$LOCK_FILE" ]]; then
    # Check if lock is stale (older than 60 seconds)
    if [[ "$(uname)" == "Darwin" ]]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE") ))
    else
        LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ))
    fi
    if [[ $LOCK_AGE -lt 60 ]]; then
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Load remote config
source "$REMOTE_FILE"

# Load backend
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_FILE="$SCRIPT_DIR/backends/${REMOTE_BACKEND}.sh"
if [[ ! -f "$BACKEND_FILE" ]]; then
    exit 1
fi
source "$BACKEND_FILE"

# Stage files to push
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"; rm -f "$LOCK_FILE"' EXIT

# Copy session-state
if [[ -f "$PARA_LLM_ROOT/recovery/session-state" ]]; then
    cp "$PARA_LLM_ROOT/recovery/session-state" "$STAGING_DIR/"
fi

# Copy config
if [[ -f "$PARA_LLM_ROOT/config" ]]; then
    cp "$PARA_LLM_ROOT/config" "$STAGING_DIR/"
fi

# Push to remote
backend_push "$STAGING_DIR"
