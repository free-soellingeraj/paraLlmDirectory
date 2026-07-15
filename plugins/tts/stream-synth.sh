#!/usr/bin/env bash
# stream-synth.sh - speak mode's synthesis worker.
# Consumes chunks/NNNNN.txt in order and produces audio/NNNNN.mp3 (edge-tts,
# retry once, then local `say` fallback as .aiff). Runs ahead of the player so
# synthesis latency is hidden after the first sentence.
#
# Usage: stream-synth.sh <pane_id> <spool_dir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANE_ID="${1:?usage: stream-synth.sh <pane_id> <spool_dir>}"
SPOOL="${2:?usage: stream-synth.sh <pane_id> <spool_dir>}"

TTS_DIR="/tmp/para-llm-tts"
STREAM_PANE_FILE="$TTS_DIR/stream.pane"
SAFE_PANE_ID="${PANE_ID#%}"

BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
fi

TTS_VOICE="${TTS_VOICE:-en-US-AndrewNeural}"
TTS_RATE="${TTS_RATE:-+0%}"
TTS_VOLUME="${TTS_VOLUME:-+0%}"
TTS_PITCH="${TTS_PITCH:-+0Hz}"
TTS_SYNTH_TIMEOUT="${TTS_SYNTH_TIMEOUT:-20}"
TTS_STREAM_ENGINE="${TTS_STREAM_ENGINE:-edge-tts}"
TTS_STREAM_MAX_LAG_SECS="${TTS_STREAM_MAX_LAG_SECS:-20}"
# Stream mode speaks slightly faster than one-shot playback: reading speed is
# the pipeline's bottleneck, and +10% meaningfully raises throughput.
TTS_RATE="${TTS_STREAM_RATE:-+10%}"

source "$SCRIPT_DIR/tts-lib.sh"

CHUNKS="$SPOOL/chunks"
AUDIO="$SPOOL/audio"
ERROR_LOG="$SPOOL/error.log"
mkdir -p "$AUDIO"

log_error() {
    printf '%s  synth: %s\n' "$(date '+%H:%M:%S')" "$*" >> "$ERROR_LOG" 2>/dev/null || true
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
    chunk="$CHUNKS/$seq.txt"
    if [[ ! -f "$chunk" ]]; then
        sleep 0.3
        continue
    fi

    # Don't waste synthesis on stale commentary (see stream-player.sh).
    if [[ "$TTS_STREAM_MAX_LAG_SECS" != "0" ]]; then
        chunk_mtime="$(stat -f %m "$chunk" 2>/dev/null || stat -c %Y "$chunk" 2>/dev/null || echo 0)"
        if (( $(date +%s) - chunk_mtime > TTS_STREAM_MAX_LAG_SECS )); then
            log_error "skipped stale text chunk $seq"
            rm -f "$chunk"
            next=$((next + 1))
            continue
        fi
    fi

    done_file=""
    if [[ "$TTS_STREAM_ENGINE" != "say" ]] && command -v edge-tts >/dev/null 2>&1; then
        out="$AUDIO/$seq.mp3"
        synth_err="$SPOOL/edge-tts.err"
        if ! synthesize_chunk "$chunk" "$out.part" "$synth_err"; then
            log_error "edge-tts failed for chunk $seq; retrying once"
            sed 's/^/edge-tts: /' "$synth_err" >> "$ERROR_LOG" 2>/dev/null || true
            rm -f "$out.part"
            sleep 0.5
            synthesize_chunk "$chunk" "$out.part" "$synth_err" || rm -f "$out.part"
        fi
        if [[ -s "$out.part" ]]; then
            mv "$out.part" "$out"
            done_file="$out"
        fi
    fi

    if [[ -z "$done_file" ]]; then
        out="$AUDIO/$seq.aiff"
        if synthesize_local_chunk "$chunk" "$out.part.aiff" && [[ -s "$out.part.aiff" ]]; then
            mv "$out.part.aiff" "$out"
            done_file="$out"
        else
            rm -f "$out.part.aiff"
            log_error "all engines failed for chunk $seq; skipping: $(cat "$chunk" 2>/dev/null | head -c 80)"
        fi
    fi

    rm -f "$chunk"
    next=$((next + 1))
done
