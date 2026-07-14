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
    echo "#[fg=green,bold]🔊SPEAK %$safe#[default]"
else
    # Stale mode file (watcher gone) — clear it so the indicator can't lie.
    rm -f "$STREAM_PANE_FILE"
fi
