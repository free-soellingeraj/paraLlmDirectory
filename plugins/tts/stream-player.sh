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
TTS_STREAM_MODE="${TTS_STREAM_MODE:-stream}"
if [[ "$TTS_STREAM_MODE" == "digest" ]]; then
    # Digests are enqueued as one batch and must play out in full.
    TTS_STREAM_MAX_LAG_SECS="${TTS_STREAM_MAX_LAG_SECS:-120}"
else
    TTS_STREAM_MAX_LAG_SECS="${TTS_STREAM_MAX_LAG_SECS:-30}"
fi

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

# Recently played chunks are kept (last 4) so "rewind" can restore them; the
# wake listener requests seeks by writing "back N" / "skip N" to player.cmd
# and killing the in-flight afplay so this loop reacts promptly.
PLAYED="$SPOOL/played"
CMD="$SPOOL/player.cmd"
mkdir -p "$PLAYED"

log_player() {
    printf '%s  player: %s\n' "$(date '+%H:%M:%S')" "$*" >> "$SPOOL/error.log" 2>/dev/null || true
}

handle_cmd() {
    [[ -s "$CMD" ]] || return 0
    local cmd n i seqp f
    read -r cmd n < "$CMD" || true
    : > "$CMD"
    case "$cmd" in
        back)
            for ((i = 0; i < ${n:-1}; i++)); do
                seqp="$(printf '%05d' $((next - 1)))"
                f="$(ls "$PLAYED/$seqp".* 2>/dev/null | head -1)"
                [[ -n "$f" ]] || break
                mv "$f" "$AUDIO/"
                # Fresh mtime, or the stale-skip would discard the rewind.
                touch "$AUDIO/$(basename "$f")"
                next=$((next - 1))
            done
            log_player "rewound to chunk $next"
            ;;
        skip)
            for ((i = 0; i < ${n:-1}; i++)); do
                seqp="$(printf '%05d' "$next")"
                f="$(ls "$AUDIO/$seqp".* 2>/dev/null | head -1)"
                [[ -n "$f" ]] || break
                rm -f "$f"
                next=$((next + 1))
            done
            log_player "skipped forward to chunk $next"
            ;;
    esac
}

next=1
while mode_active; do
    handle_cmd
    seq="$(printf '%05d' "$next")"
    # A tombstone marks a sequence number the synth skipped — consume it or
    # the strict in-order wait below deadlocks on the hole.
    if [[ -f "$AUDIO/$seq.skip" ]]; then
        rm -f "$AUDIO/$seq.skip"
        next=$((next + 1))
        continue
    fi
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

    if [[ "$TTS_STREAM_MAX_LAG_SECS" != "0" && ! -f "$AUDIO/$seq.keep" ]] \
        && [[ "$(file_age "$file")" -gt "$TTS_STREAM_MAX_LAG_SECS" ]]; then
        log_player "skipped stale chunk $seq"
        rm -f "$file"
        next=$((next + 1))
        continue
    fi

    age="$(file_age "$file")"
    if [[ "$age" -gt 15 ]]; then
        log_player "chunk $seq played ${age}s late"
    fi
    afplay "$file" 2>> "$SPOOL/error.log" || true
    rm -f "$AUDIO/$seq.keep"
    mv "$file" "$PLAYED/" 2>/dev/null || rm -f "$file"
    next=$((next + 1))
    # Prune the rewind buffer to the last 4 chunks.
    while [[ "$(ls -1 "$PLAYED" 2>/dev/null | wc -l | tr -d ' ')" -gt 4 ]]; do
        rm -f "$PLAYED/$(ls -1 "$PLAYED" | sort | head -1)"
    done
done
