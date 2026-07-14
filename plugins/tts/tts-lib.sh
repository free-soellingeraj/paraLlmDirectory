#!/usr/bin/env bash
# tts-lib.sh - shared helpers for the TTS plugins.
# Sourced by toggle-tts.sh (Ctrl+b p one-shot playback) and the speak-mode
# scripts (Ctrl+b o streaming). Callers must set TTS_DIR and the TTS_* config
# variables before invoking the synthesis functions; the functions read them
# dynamically at call time.

# Resolve a `timeout`-style command (GNU coreutils ships it as `gtimeout` on
# macOS). Empty if neither is available, in which case calls run uncapped.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi

# Kill a process and all of its descendants (the summarizer's claude/codex
# child, edge-tts, afplay), so a stop actually interrupts in-flight work.
kill_tree() {
    local pid="$1" child
    [[ -z "$pid" ]] && return 0
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child"
    done
    kill "$pid" 2>/dev/null || true
}

# Stop any one-shot (Ctrl+b p) playback state for a pane, by SAFE_PANE_ID.
stop_playback_for_pane() {
    local safe="$1"
    [[ -z "$safe" ]] && return 0
    local p_pid p_prep p_amb p_prog pid
    p_pid="$TTS_DIR/$safe.pid"
    p_prep="$TTS_DIR/$safe.prep.pid"
    p_amb="$TTS_DIR/$safe.ambient.pid"
    p_prog="$TTS_DIR/$safe.progress.pid"
    if [[ -f "$p_pid" ]]; then
        pid="$(cat "$p_pid" 2>/dev/null)"
        [[ -n "$pid" ]] && kill_tree "$pid"
        rm -f "$p_pid"
    fi
    if [[ -f "$p_prep" ]]; then
        pid="$(cat "$p_prep" 2>/dev/null)"
        if [[ -n "$pid" && "$pid" != "$$" ]]; then
            kill_tree "$pid"
        fi
        rm -f "$p_prep"
    fi
    if [[ -f "$p_amb" ]]; then
        pid="$(cat "$p_amb" 2>/dev/null)"
        [[ -n "$pid" ]] && kill_tree "$pid"
        rm -f "$p_amb"
    fi
    if [[ -f "$p_prog" ]]; then
        pid="$(cat "$p_prog" 2>/dev/null)"
        [[ -n "$pid" ]] && kill_tree "$pid"
        rm -f "$p_prog"
    fi
    rm -f "$TTS_DIR/$safe.phase"
    rm -f "$TTS_DIR/$safe.mp3"
    rm -f "$TTS_DIR/$safe.audio-list"
    rm -rf "$TTS_DIR/$safe.audio"
}

split_speech_for_synthesis() {
    local input_file="$1"
    local chunk_dir="$2"
    local max_chars="$3"

    python3 - "$input_file" "$chunk_dir" "$max_chars" <<'PY'
import os
import re
import sys
from pathlib import Path

input_file, chunk_dir, max_chars_raw = sys.argv[1:4]
max_chars = max(200, int(max_chars_raw))
text = Path(input_file).read_text(errors="replace").strip()
text = re.sub(r"\s+", " ", text)
if not text:
    sys.exit(1)

sentences = re.split(r"(?<=[.!?])\s+", text)
chunks = []
current = ""

def push(value):
    value = value.strip()
    if value:
        chunks.append(value)

for sentence in sentences:
    sentence = sentence.strip()
    if not sentence:
        continue
    if len(sentence) > max_chars:
        words = sentence.split()
        for word in words:
            if len(current) + len(word) + 1 <= max_chars:
                current = f"{current} {word}".strip()
            else:
                push(current)
                current = word
        continue
    if len(current) + len(sentence) + 1 <= max_chars:
        current = f"{current} {sentence}".strip()
    else:
        push(current)
        current = sentence

push(current)

os.makedirs(chunk_dir, exist_ok=True)
for index, chunk in enumerate(chunks, start=1):
    Path(chunk_dir, f"chunk-{index:03d}.txt").write_text(chunk + "\n")
PY
}

synthesize_chunk() {
    local input_file="$1"
    local output_file="$2"
    local synth_err="$3"
    local synth_cmd=(edge-tts
        --file "$input_file"
        --voice "$TTS_VOICE"
        --rate "$TTS_RATE"
        --volume "$TTS_VOLUME"
        --pitch "$TTS_PITCH"
        --write-media "$output_file")
    if [[ -n "$TIMEOUT_CMD" && "$TTS_SYNTH_TIMEOUT" != "0" ]]; then
        synth_cmd=("$TIMEOUT_CMD" -k 5 "$TTS_SYNTH_TIMEOUT" "${synth_cmd[@]}")
    fi

    "${synth_cmd[@]}" > /dev/null 2> "$synth_err"
}

synthesize_local_chunk() {
    local input_file="$1"
    local output_file="$2"
    command -v say >/dev/null 2>&1 || return 1
    say -f "$input_file" -o "$output_file" >/dev/null 2>&1
}
