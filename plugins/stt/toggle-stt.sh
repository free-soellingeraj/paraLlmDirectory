#!/usr/bin/env bash

# Toggle speech-to-text recording for the active tmux pane
# Called by tmux key binding: Ctrl+b a
#
# First press:  start recording from microphone
# Second press: stop recording, transcribe, inject text into pane

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STT_DIR="/tmp/para-llm-stt"
PID_FILE="$STT_DIR/recording.pid"
TARGET_FILE="$STT_DIR/target-pane"
AUDIO_FILE="$STT_DIR/audio.wav"

mkdir -p "$STT_DIR"

# Check dependencies
check_deps() {
    if ! command -v rec &>/dev/null; then
        tmux display-message "STT Error: 'rec' not found. Install sox with your package manager (e.g., brew install sox / apt install sox)"
        exit 1
    fi
    if ! command -v whisper-cli &>/dev/null && ! command -v whisper-cpp &>/dev/null; then
        tmux display-message "STT Error: whisper-cli not found. Install whisper-cpp with your package manager (e.g., brew install whisper-cpp / apt install whisper-cpp)"
        exit 1
    fi
}

# Check if recording is actually running (handles stale PID files)
is_recording() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            # Stale PID file - clean up
            rm -f "$PID_FILE" "$TARGET_FILE" "$AUDIO_FILE"
        fi
    fi
    # Fallback: a recorder is running but the PID file is missing (desynced
    # state from a prior crash/race/kill). Without this re-adoption, the toggle
    # would think nothing is recording and start a SECOND rec on every press,
    # stacking orphans that permanently hold the mic. Re-adopt it so the next
    # press stops it.
    local orphan
    orphan=$(pgrep -f "rec -b 16 -c 1 -r 16000 $AUDIO_FILE" 2>/dev/null | head -1)
    if [[ -n "$orphan" ]]; then
        echo "$orphan" > "$PID_FILE"
        return 0
    fi
    return 1
}

# Stop a recorder. SIGTERM lets sox flush a clean WAV, but sox can ignore TERM
# while wedged in CoreAudio teardown (observed: a rec stuck ~24h surviving the
# in-script SIGTERM), so escalate to an uncatchable SIGKILL after a short grace.
kill_recorder() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    kill "$pid" 2>/dev/null || return 0
    local n=0
    while kill -0 "$pid" 2>/dev/null; do
        n=$((n + 1))
        if [[ $n -gt 15 ]]; then       # ~3s grace, then force
            kill -9 "$pid" 2>/dev/null || true
            break
        fi
        sleep 0.2
    done
}

start_recording() {
    check_deps

    # Save the currently active pane as injection target
    local active_pane
    active_pane=$(tmux display-message -p '#{pane_id}')
    echo "$active_pane" > "$TARGET_FILE"

    # Kill any orphaned recorder from a previous desynced toggle before we
    # start a new one, so we never leave a stray rec holding the mic. Use the
    # escalating killer since a plain pkill -TERM may be ignored.
    local opid
    for opid in $(pgrep -f "rec -b 16 -c 1 -r 16000 $AUDIO_FILE" 2>/dev/null); do
        kill_recorder "$opid"
    done

    # Remove old audio file
    rm -f "$AUDIO_FILE"

    # Start recording: 16-bit, mono, 16kHz WAV (whisper.cpp input format).
    # Capture rec's stderr so silent-failure modes (denied mic permission, no
    # default input device, sox driver errors) leave a trail we can read.
    rec -b 16 -c 1 -r 16000 "$AUDIO_FILE" 2>"$STT_DIR/rec.log" &
    local rec_pid=$!
    echo "$rec_pid" > "$PID_FILE"

    tmux display-message "Recording... (Ctrl+b a to stop and transcribe)"
}

stop_and_transcribe() {
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)

    # Stop recording (escalates to SIGKILL if sox ignores SIGTERM)
    if [[ -n "$pid" ]]; then
        kill_recorder "$pid"
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"

    # Read target pane
    local target_pane
    target_pane=$(cat "$TARGET_FILE" 2>/dev/null)
    rm -f "$TARGET_FILE"

    if [[ ! -f "$AUDIO_FILE" ]]; then
        tmux display-message "STT Error: No audio file recorded"
        return 1
    fi

    # Check audio file has content (more than just WAV header)
    local file_size
    file_size=$(stat -f%z "$AUDIO_FILE" 2>/dev/null || stat -c%s "$AUDIO_FILE" 2>/dev/null || echo "0")
    if [[ "$file_size" -lt 1000 ]]; then
        tmux display-message "STT: Recording too short, nothing to transcribe"
        rm -f "$AUDIO_FILE"
        return 1
    fi

    # Detect silent / near-silent audio before invoking Whisper. Whisper's
    # ggml-base.en model has a strong prior to emit "you" / "thank you" on
    # silent input, so without this guard a denied mic permission looks like
    # a transcription bug. RMS is on a 0..1 scale; room tone is ~0.001-0.003.
    if command -v sox &>/dev/null; then
        local rms
        rms=$(sox "$AUDIO_FILE" -n stat 2>&1 | awk '/RMS[[:space:]]+amplitude/ {print $NF; exit}')
        if [[ -n "$rms" ]] && awk -v r="$rms" 'BEGIN { exit !(r+0 < 0.003) }'; then
            tmux display-message "STT: no audible audio (RMS=$rms; check mic permission for your terminal app)"
            rm -f "$AUDIO_FILE"
            return 1
        fi
    fi

    tmux display-message "Transcribing..."

    # Transcribe
    local text
    text=$("$SCRIPT_DIR/transcribe.sh" "$AUDIO_FILE" 2>/dev/null)

    # Clean up audio
    rm -f "$AUDIO_FILE"

    if [[ -z "$text" ]]; then
        tmux display-message "STT: No speech detected"
        return 1
    fi

    # Inject transcribed text into target pane
    if [[ -n "$target_pane" ]]; then
        tmux send-keys -t "$target_pane" -l "$text"
    else
        # Fallback: send to current pane
        tmux send-keys -l "$text"
    fi

    # Show preview (truncate long text)
    local preview="$text"
    if [[ ${#preview} -gt 60 ]]; then
        preview="${preview:0:60}..."
    fi
    tmux display-message "Transcribed: $preview"
}

# Main toggle logic
if is_recording; then
    stop_and_transcribe
else
    start_recording
fi
