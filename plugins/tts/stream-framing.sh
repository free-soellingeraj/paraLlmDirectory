#!/usr/bin/env bash
# stream-framing.sh - speak-mode enable preamble.
# Scans back through the pane's recent transcript, summarizes "what is
# currently happening" via the TTS summarizer (codex, see ADR-009), and
# enqueues it as the FIRST audio chunks. While framing.lock exists the watcher
# accumulates new settled text without emitting, so the recap always plays
# before the live stream — which then starts from the moment of enablement.
#
# Usage: stream-framing.sh <pane_id> <spool_dir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANE_ID="${1:?usage: stream-framing.sh <pane_id> <spool_dir>}"
SPOOL="${2:?usage: stream-framing.sh <pane_id> <spool_dir>}"

TTS_DIR="/tmp/para-llm-tts"
STREAM_PANE_FILE="$TTS_DIR/stream.pane"
SAFE_PANE_ID="${PANE_ID#%}"
LOCK="$SPOOL/framing.lock"

BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
fi

TTS_SUMMARIZE="${TTS_SUMMARIZE:-1}"
TTS_SUMMARIZER_BACKEND="${TTS_SUMMARIZER_BACKEND:-codex}"
TTS_SYNTH_CHARS="${TTS_SYNTH_CHARS:-180}"
TTS_AMBIENT_SOUND_ENABLED="${TTS_AMBIENT_SOUND_ENABLED:-1}"
TTS_AMBIENT_SOUND_INTERVAL="${TTS_AMBIENT_SOUND_INTERVAL:-1}"
TTS_AMBIENT_SOUND="${TTS_AMBIENT_SOUND:-/System/Library/Sounds/Tink.aiff}"
TTS_AMBIENT_MAX_SECONDS="${TTS_AMBIENT_MAX_SECONDS:-120}"

source "$SCRIPT_DIR/tts-lib.sh"

log_lifecycle() {
    printf '%s  framing[%s]  %s\n' "$(date '+%F %T')" "$PANE_ID" "$*" \
        >> "$TTS_DIR/stream.log" 2>/dev/null || true
}

AMBIENT_PID=""
stop_ambient() {
    [[ -n "$AMBIENT_PID" ]] && kill "$AMBIENT_PID" 2>/dev/null
    AMBIENT_PID=""
}

# Releasing the lock is what un-gates the watcher — it must happen no matter
# how this script exits, or streaming would never start.
cleanup() {
    stop_ambient
    rm -f "$LOCK"
}
trap cleanup EXIT
trap 'cleanup; exit 0' TERM INT

mode_active() {
    [[ "$(cat "$STREAM_PANE_FILE" 2>/dev/null)" == "$SAFE_PANE_ID" ]]
}

# Wait for the mode file like the other workers (see toggle-stream start order).
tries=0
until mode_active; do
    tries=$((tries + 1))
    [[ "$tries" -gt 20 ]] && exit 0
    sleep 0.1
done

if [[ "$TTS_SUMMARIZE" == "0" ]]; then
    log_lifecycle "skipped: TTS_SUMMARIZE=0"
    exit 0
fi

# "Preparing" cue while the summarizer runs, same as one-shot playback.
if [[ "$TTS_AMBIENT_SOUND_ENABLED" != "0" ]] && command -v afplay >/dev/null 2>&1 \
    && [[ -f "$TTS_AMBIENT_SOUND" ]]; then
    (
        SECONDS=0
        while true; do
            afplay "$TTS_AMBIENT_SOUND" >/dev/null 2>&1 || true
            [[ "$TTS_AMBIENT_MAX_SECONDS" != "0" && "$SECONDS" -ge "$TTS_AMBIENT_MAX_SECONDS" ]] && break
            sleep "$TTS_AMBIENT_SOUND_INTERVAL"
        done
    ) &
    AMBIENT_PID=$!
fi

PANE_PATH="$(tmux display-message -pt "$PANE_ID" '#{pane_current_path}' 2>/dev/null || pwd)"

"$SCRIPT_DIR/extract-latest.sh" "$PANE_ID" > "$SPOOL/framing.txt"
if [[ ! -s "$SPOOL/framing.txt" ]]; then
    log_lifecycle "skipped: no readable pane text"
    exit 0
fi

if ! "$SCRIPT_DIR/summarize-for-speech.sh" "$TTS_SUMMARIZER_BACKEND" \
        "$SPOOL/framing.txt" "$SPOOL/framing.speech" "$PANE_PATH" >/dev/null 2>&1 \
    || [[ ! -s "$SPOOL/framing.speech" ]]; then
    log_lifecycle "skipped: summarizer failed or empty"
    exit 0
fi

# A stop/move may have arrived during the (slow) summarize.
mode_active || exit 0

# Lead-in so the recap is audibly distinct from the live stream that follows.
# Cap the recap at ~2 sentences-worth of audio: a minute-long recap monologue
# starves the live stream (everything arriving meanwhile goes stale).
python3 - "$SPOOL/framing.speech" "${TTS_STREAM_RECAP_CHARS:-400}" > "$SPOOL/framing.final" <<'CAPPY'
import re, sys
text = open(sys.argv[1], errors="replace").read().strip()
limit = int(sys.argv[2])
text = re.sub(r"\s+", " ", text)
if len(text) > limit:
    cut = text.rfind(". ", 0, limit)
    text = text[:cut + 1] if cut > 40 else text[:limit]
print("Recap. " + text)
CAPPY

chunk_dir="$SPOOL/framing.chunks"
if ! split_speech_for_synthesis "$SPOOL/framing.final" "$chunk_dir" "$TTS_SYNTH_CHARS"; then
    log_lifecycle "skipped: could not split summary"
    exit 0
fi

stop_ambient

# Enqueue ahead of the live stream. The watcher is emission-gated by the lock,
# so the .next counter is ours alone right now.
next="$(cat "$SPOOL/chunks/.next" 2>/dev/null || echo 1)"
count=0
for chunk in "$chunk_dir"/chunk-*.txt; do
    [[ -f "$chunk" ]] || continue
    final="$SPOOL/chunks/$(printf '%05d' "$next").txt"
    mv "$chunk" "$final"
    next=$((next + 1))
    count=$((count + 1))
done
echo "$next" > "$SPOOL/chunks/.next"
rm -rf "$chunk_dir"
log_lifecycle "enqueued recap: $count chunk(s)"
