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
    # The label was resolved once at enable time by toggle-stream.sh —
    # re-deriving it here via display-message would silently read a DIFFERENT
    # pane if the bound pane died (tmux falls back instead of failing).
    label="$(cat "$TTS_DIR/$safe.stream/label" 2>/dev/null)"
    [[ -z "$label" ]] && label="pane $safe"
    echo "#[bg=colour201,fg=colour231,bold] 🔊SPEAK $label #[default]"
else
    # Watcher not (yet) alive. Only treat the mode file as stale after a
    # grace period — this script can run mid-startup (a border-option change
    # in toggle-stream triggers a status redraw), and clearing stream.pane
    # then kills the mode before it begins (BUG-022).
    now="$(date +%s)"
    mtime="$(stat -f %m "$STREAM_PANE_FILE" 2>/dev/null || stat -c %Y "$STREAM_PANE_FILE" 2>/dev/null || echo "$now")"
    if (( now - mtime > 15 )); then
        rm -f "$STREAM_PANE_FILE"
    fi
fi
