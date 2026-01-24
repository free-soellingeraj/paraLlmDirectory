#!/usr/bin/env bash
# para-llm-do-discard.sh - Discard recovery state
# Called from recovery prompt menu

set -u

BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    exit 1
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"

# Remove recovery state
rm -f "$PARA_LLM_ROOT/recovery/session-state"

# Remove resurrect save files
rm -rf "$PARA_LLM_ROOT/recovery/resurrect/"*

tmux display-message "para-llm: Recovery state discarded. Fresh start."
