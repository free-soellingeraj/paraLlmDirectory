#!/usr/bin/env bash
# extract-latest.sh - extract speakable recent text from a tmux pane.

set -uo pipefail

PANE_ID="${1:-}"
if [[ -z "$PANE_ID" ]]; then
    PANE_ID="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
fi

if [[ -z "$PANE_ID" ]]; then
    exit 1
fi

tmux capture-pane -t "$PANE_ID" -p -S - 2>/dev/null \
    | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\r//g' \
    | sed \
        -e '/^[[:space:]]*$/d' \
        -e '/esc to interrupt/d' \
        -e '/ctrl.*enter/d' \
        -e '/shift.*tab/d' \
        -e '/Press enter to continue/d' \
        -e '/Do you trust the contents of this directory/d' \
        -e '/Working with untrusted contents/d' \
        -e '/project-local config, hooks, and exec policies/d' \
        -e '/^[[:space:]]*[›>]*[[:space:]]*[12]\. \(Yes, continue\|No, quit\)/d' \
        -e '/^[[:space:]]*[╭╰│]/d' \
    | tail -n 240
