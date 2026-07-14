#!/usr/bin/env bash
# Speak mode indicator for the tmux status line.
# Shows "SPEAK %N" (green) while streaming TTS is bound to pane N; empty
# otherwise. Cleans up if the watcher died without clearing the mode file.

TTS_DIR="/tmp/para-llm-tts"
STREAM_PANE_FILE="$TTS_DIR/stream.pane"

[[ -f "$STREAM_PANE_FILE" ]] || exit 0

safe="$(cat "$STREAM_PANE_FILE" 2>/dev/null)"
[[ -n "$safe" ]] || exit 0

watcher_pid="$(cat "$TTS_DIR/$safe.stream/watcher.pid" 2>/dev/null)"
if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
    # Label the bound pane by its branch (how envs are identified here),
    # falling back to the directory name — a raw pane id like %4 means
    # nothing in the status line.
    dir="$(tmux display-message -pt "%$safe" '#{pane_current_path}' 2>/dev/null)"
    label=""
    if [[ -n "$dir" ]]; then
        label="$(git -C "$dir" branch --show-current 2>/dev/null)"
        [[ -z "$label" ]] && label="${dir##*/}"
    fi
    [[ -z "$label" ]] && label="pane $safe"
    label="${label:0:24}"
    echo "#[bg=colour201,fg=colour231,bold] 🔊SPEAK $label #[default]"
else
    # Stale mode file (watcher gone) — clear it so the indicator can't lie.
    rm -f "$STREAM_PANE_FILE"
fi
