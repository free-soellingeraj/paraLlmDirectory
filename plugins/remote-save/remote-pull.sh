#!/usr/bin/env bash
# remote-pull.sh - Pull state files from active remote to local recovery
# Used before remote restore to fetch latest state

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

REMOTES_DIR="$PARA_LLM_ROOT/remotes"
ACTIVE_FILE="$REMOTES_DIR/.active"

# Check active remote
if [[ ! -f "$ACTIVE_FILE" ]]; then
    echo "No active remote configured."
    exit 1
fi
ACTIVE_REMOTE=$(cat "$ACTIVE_FILE")
REMOTE_FILE="$REMOTES_DIR/$ACTIVE_REMOTE"
if [[ ! -f "$REMOTE_FILE" ]]; then
    echo "Remote config '$ACTIVE_REMOTE' not found."
    exit 1
fi

# Load remote config and backend
source "$REMOTE_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_FILE="$SCRIPT_DIR/backends/${REMOTE_BACKEND}.sh"
if [[ ! -f "$BACKEND_FILE" ]]; then
    echo "Backend '${REMOTE_BACKEND}' not found."
    exit 1
fi
source "$BACKEND_FILE"

# Pull to recovery directory
PULL_DIR="$PARA_LLM_ROOT/recovery"
mkdir -p "$PULL_DIR"

echo "Pulling state from remote '$ACTIVE_REMOTE'..."
if backend_pull "$PULL_DIR"; then
    echo "Pull complete."
    if [[ -f "$PULL_DIR/session-state" ]]; then
        echo ""
        echo "Session state:"
        grep -v "^#" "$PULL_DIR/session-state" | grep -v "^window_name" | while IFS='|' read -r win ppath proj branch claude remote_url; do
            echo "  $proj/$branch (claude=$claude)"
        done
    fi
else
    echo "Pull failed."
    exit 1
fi
