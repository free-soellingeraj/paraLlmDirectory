#!/usr/bin/env bash
# stream-player.sh - speak mode's playback worker.
# Plays audio/NNNNN.(mp3|aiff) strictly in sequence, waiting when the next
# chunk hasn't been synthesized yet. No ambient "preparing" beep: speak mode
# is a long-lived mode, and constant beeping between utterances would be noise.
#
# Usage: stream-player.sh <pane_id> <spool_dir>

set -uo pipefail

PANE_ID="${1:?usage: stream-player.sh <pane_id> <spool_dir>}"
SPOOL="${2:?usage: stream-player.sh <pane_id> <spool_dir>}"

TTS_DIR="/tmp/para-llm-tts"
STREAM_PANE_FILE="$TTS_DIR/stream.pane"
SAFE_PANE_ID="${PANE_ID#%}"
AUDIO="$SPOOL/audio"

mode_active() {
    [[ "$(cat "$STREAM_PANE_FILE" 2>/dev/null)" == "$SAFE_PANE_ID" ]]
}

# The mode file is written shortly AFTER we are spawned (see toggle-stream.sh
# start order) — wait briefly for it instead of exiting on a not-yet-on mode.
tries=0
until mode_active; do
    tries=$((tries + 1))
    [[ "$tries" -gt 20 ]] && exit 0
    sleep 0.1
done

next=1
while mode_active; do
    seq="$(printf '%05d' "$next")"
    file=""
    for candidate in "$AUDIO/$seq.mp3" "$AUDIO/$seq.aiff"; do
        if [[ -f "$candidate" ]]; then
            file="$candidate"
            break
        fi
    done

    if [[ -z "$file" ]]; then
        sleep 0.2
        continue
    fi

    afplay "$file" 2>> "$SPOOL/error.log" || true
    rm -f "$file"
    next=$((next + 1))
done
