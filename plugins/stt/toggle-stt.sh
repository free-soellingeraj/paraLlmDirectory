#!/usr/bin/env bash

# Toggle speech-to-text recording for the active tmux pane
# Called by tmux key binding: Ctrl+b x
#
# First press:  start recording from microphone
# Second press: stop recording, transcribe, inject text into pane

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STT_DIR="/tmp/claude-stt"
PID_FILE="$STT_DIR/recording.pid"
TARGET_FILE="$STT_DIR/target-pane"
AUDIO_FILE="$STT_DIR/audio.wav"

mkdir -p "$STT_DIR"

# Check dependencies
check_deps() {
    if ! command -v rec &>/dev/null; then
        tmux display-message "STT Error: 'rec' not found. Install with: brew install sox"
        exit 1
    fi
    if ! command -v whisper-cli &>/dev/null && ! command -v whisper-cpp &>/dev/null; then
        tmux display-message "STT Error: whisper-cli not found. Install with: brew install whisper-cpp"
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
            return 1
        fi
    fi
    return 1
}

start_recording() {
    check_deps

    # Save the currently active pane as injection target
    local active_pane
    active_pane=$(tmux display-message -p '#{pane_id}')
    echo "$active_pane" > "$TARGET_FILE"

    # Remove old audio file
    rm -f "$AUDIO_FILE"

    # Start recording: 16-bit, mono, 16kHz WAV (whisper.cpp input format)
    rec -q -b 16 -c 1 -r 16000 "$AUDIO_FILE" &
    local rec_pid=$!
    echo "$rec_pid" > "$PID_FILE"

    tmux display-message "Recording... (Ctrl+b a to stop and transcribe)"
}

stop_and_transcribe() {
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)

    # Stop recording
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null
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
