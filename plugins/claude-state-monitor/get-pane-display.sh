#!/usr/bin/env bash
# Fast pane display lookup - called frequently by tmux pane-border-format

pane_id="${1:-}"
[[ -z "$pane_id" ]] && exit 0

# Strip % prefix
safe_id="${pane_id#%}"

# Check standard location first (fast path)
f="$HOME/.para-llm-directory/recovery/pane-display/$safe_id"
[[ -f "$f" ]] && cat "$f" && exit 0

# Fallback: read bootstrap file
if [[ -f "$HOME/.para-llm-root" ]]; then
    f="$(cat "$HOME/.para-llm-root")/recovery/pane-display/$safe_id"
    [[ -f "$f" ]] && cat "$f" && exit 0
fi

# Last fallback
f="/tmp/claude-pane-display/$safe_id"
[[ -f "$f" ]] && cat "$f" && exit 0

echo ""
