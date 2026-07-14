#!/usr/bin/env bash
# extract-latest.sh - extract speakable recent text from a tmux pane.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PANE_ID="${1:-}"
if [[ -z "$PANE_ID" ]]; then
    PANE_ID="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
fi

if [[ -z "$PANE_ID" ]]; then
    exit 1
fi

tmux capture-pane -t "$PANE_ID" -p -S - 2>/dev/null \
    | "$SCRIPT_DIR/filter-pane-text.sh" \
    | tail -n 240
