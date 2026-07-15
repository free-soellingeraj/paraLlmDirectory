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

BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    [[ -f "$PARA_LLM_ROOT/config" ]] && source "$PARA_LLM_ROOT/config"
fi
# Freshness beats completeness: audio synthesized longer ago than this is
# stale commentary — skip it so speech stays near-live and pauses (during
# which voice commands match leniently) actually occur. 0 disables.
TTS_STREAM_MAX_LAG_SECS="${TTS_STREAM_MAX_LAG_SECS:-45}"

file_age() {
    local m
    m="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)"
    echo $(( $(date +%s) - m ))
}

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

    if [[ "$TTS_STREAM_MAX_LAG_SECS" != "0" ]] \
        && [[ "$(file_age "$file")" -gt "$TTS_STREAM_MAX_LAG_SECS" ]]; then
        printf '%s  player: skipped stale chunk %s\n' "$(date '+%H:%M:%S')" "$seq" \
            >> "$SPOOL/error.log" 2>/dev/null || true
        rm -f "$file"
        next=$((next + 1))
        continue
    fi

    age="$(file_age "$file")"
    if [[ "$age" -gt 15 ]]; then
        printf '%s  player: chunk %s played %ss late\n' "$(date '+%H:%M:%S')" "$seq" "$age" \
            >> "$SPOOL/error.log" 2>/dev/null || true
    fi
    afplay "$file" 2>> "$SPOOL/error.log" || true
    rm -f "$file"
    next=$((next + 1))
done
