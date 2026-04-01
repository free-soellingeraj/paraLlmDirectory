#!/usr/bin/env bash
# openshell-status.sh - tmux status-right segment for OpenShell
# Shows count of active sandboxes (e.g., "OS:2")
# Called by tmux status-right: #(path/to/openshell-status.sh)

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

# Exit if OpenShell not enabled
if [[ "${OPENSHELL_ENABLED:-0}" != "1" ]]; then
    exit 0
fi

SANDBOX_STATE_DIR="$PARA_LLM_ROOT/openshell/state/sandboxes"

# Count active sandbox state files
count=0
if [[ -d "$SANDBOX_STATE_DIR" ]]; then
    for f in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$f" ]] && (( count++ ))
    done
fi

# Only show if there are active sandboxes
if [[ $count -gt 0 ]]; then
    echo "OS:${count}"
fi
