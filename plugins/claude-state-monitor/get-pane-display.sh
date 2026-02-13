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

# No display file found - detect git/Claude status as fallback
dir=$(tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null)
dirname="${dir##*/}"

# Check if it's a git repo
branch=$(git -C "$dir" branch --show-current 2>/dev/null)
if [[ -z "$branch" ]]; then
    echo "#[fg=default]No Git | $dirname#[default]"
else
    echo "#[fg=green]No Claude | $dirname | $branch#[default]"
fi
