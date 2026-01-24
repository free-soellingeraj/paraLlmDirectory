#!/usr/bin/env bash
# para-llm-do-restore.sh - Execute the restore action
# Called from recovery prompt menu

set -u

BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    exit 1
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"

RESURRECT_DIR="$PARA_LLM_ROOT/tmux-plugins/tmux-resurrect"

# Run tmux-resurrect restore
if [[ -f "$RESURRECT_DIR/scripts/restore.sh" ]]; then
    tmux display-message "para-llm: Restoring tmux layout..."
    "$RESURRECT_DIR/scripts/restore.sh"
fi

# Wait for panes to initialize
sleep 2

# Re-launch Claude sessions
tmux display-message "para-llm: Re-launching Claude sessions..."
"$PARA_LLM_ROOT/scripts/para-llm-restore.sh"
