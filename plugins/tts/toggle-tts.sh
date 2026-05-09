#!/usr/bin/env bash
# Toggle text-to-speech playback for the active tmux pane.
# Called by tmux key binding: Ctrl+b p

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TTS_DIR="/tmp/para-llm-tts"
mkdir -p "$TTS_DIR"

BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
fi

CONFIG_LOADER="$SCRIPT_DIR/../../para-llm-config.sh"
if [[ -f "$CONFIG_LOADER" ]]; then
    source "$CONFIG_LOADER"
fi

TTS_VOICE="${TTS_VOICE:-en-US-AndrewNeural}"
TTS_RATE="${TTS_RATE:-+0%}"
TTS_VOLUME="${TTS_VOLUME:-+0%}"
TTS_PITCH="${TTS_PITCH:-+0Hz}"
TTS_SUMMARIZE="${TTS_SUMMARIZE:-1}"
TTS_SUMMARIZER_BACKEND="${TTS_SUMMARIZER_BACKEND:-auto}"

PANE_ID="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
PANE_PATH="$(tmux display-message -p -t "$PANE_ID" '#{pane_current_path}' 2>/dev/null || pwd)"
SAFE_PANE_ID="${PANE_ID#%}"
PID_FILE="$TTS_DIR/$SAFE_PANE_ID.pid"
PREP_PID_FILE="$TTS_DIR/$SAFE_PANE_ID.prep.pid"
AMBIENT_PID_FILE="$TTS_DIR/$SAFE_PANE_ID.ambient.pid"
TEXT_FILE="$TTS_DIR/$SAFE_PANE_ID.txt"
SPEECH_FILE="$TTS_DIR/$SAFE_PANE_ID.speech.txt"
AUDIO_FILE="$TTS_DIR/$SAFE_PANE_ID.mp3"

TTS_AMBIENT_SOUND_ENABLED="${TTS_AMBIENT_SOUND_ENABLED:-1}"
TTS_AMBIENT_SOUND_INTERVAL="${TTS_AMBIENT_SOUND_INTERVAL:-1}"
TTS_AMBIENT_SOUND="${TTS_AMBIENT_SOUND:-/System/Library/Sounds/Tink.aiff}"

is_playing() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    if [[ -f "$PREP_PID_FILE" ]]; then
        local prep_pid
        prep_pid="$(cat "$PREP_PID_FILE" 2>/dev/null)"
        if [[ -n "$prep_pid" ]] && kill -0 "$prep_pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PREP_PID_FILE"
    fi
    if [[ -f "$AMBIENT_PID_FILE" ]]; then
        local ambient_pid
        ambient_pid="$(cat "$AMBIENT_PID_FILE" 2>/dev/null)"
        if [[ -n "$ambient_pid" ]] && kill -0 "$ambient_pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$AMBIENT_PID_FILE"
    fi
    return 1
}

stop_playback() {
    local pid prep_pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
    fi
    prep_pid="$(cat "$PREP_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$prep_pid" && "$prep_pid" != "$$" ]]; then
        kill "$prep_pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    rm -f "$PREP_PID_FILE"
    rm -f "$AUDIO_FILE"
    stop_ambient_loop
    tmux display-message "TTS stopped"
}

stop_ambient_loop() {
    local ambient_pid
    ambient_pid="$(cat "$AMBIENT_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$ambient_pid" ]]; then
        kill "$ambient_pid" 2>/dev/null || true
    fi
    rm -f "$AMBIENT_PID_FILE"
}

cleanup_on_exit() {
    stop_ambient_loop
    rm -f "$PREP_PID_FILE"
}
trap cleanup_on_exit EXIT TERM INT

start_ambient_loop() {
    if [[ "$TTS_AMBIENT_SOUND_ENABLED" == "0" ]]; then
        return 0
    fi
    if ! command -v afplay >/dev/null 2>&1 || [[ ! -f "$TTS_AMBIENT_SOUND" ]]; then
        return 0
    fi

    stop_ambient_loop
    (
        while true; do
            afplay "$TTS_AMBIENT_SOUND" >/dev/null 2>&1 || true
            sleep "$TTS_AMBIENT_SOUND_INTERVAL"
        done
    ) &
    echo "$!" > "$AMBIENT_PID_FILE"
}

start_playback() {
    echo "$$" > "$PREP_PID_FILE"

    if ! command -v edge-tts >/dev/null 2>&1; then
        tmux display-message "TTS Error: edge-tts not found. Install with: pipx install edge-tts"
        exit 1
    fi
    if ! command -v afplay >/dev/null 2>&1; then
        tmux display-message "TTS Error: afplay not found"
        exit 1
    fi

    "$SCRIPT_DIR/extract-latest.sh" "$PANE_ID" > "$TEXT_FILE"
    if [[ ! -s "$TEXT_FILE" ]]; then
        tmux display-message "TTS: no readable pane text found"
        exit 1
    fi

    start_ambient_loop
    cp "$TEXT_FILE" "$SPEECH_FILE"
    if [[ "$TTS_SUMMARIZE" != "0" ]]; then
        local backend="$TTS_SUMMARIZER_BACKEND"
        if [[ "$backend" == "auto" && "$(type -t para_llm_repl_for_path 2>/dev/null)" == "function" ]]; then
            backend="$(para_llm_repl_for_path "$PANE_PATH" 2>/dev/null || echo "auto")"
        fi
        tmux display-message "TTS preparing speech text..."
        if ! "$SCRIPT_DIR/summarize-for-speech.sh" "$backend" "$TEXT_FILE" "$SPEECH_FILE" "$PANE_PATH" >/dev/null 2>&1; then
            cp "$TEXT_FILE" "$SPEECH_FILE"
            tmux display-message "TTS summary unavailable; using pane text"
        fi
    fi

    rm -f "$AUDIO_FILE"
    tmux display-message "TTS generating audio..."
    if ! edge-tts \
        --file "$SPEECH_FILE" \
        --voice "$TTS_VOICE" \
        --rate "$TTS_RATE" \
        --volume "$TTS_VOLUME" \
        --pitch "$TTS_PITCH" \
        --write-media "$AUDIO_FILE" >/dev/null 2>&1; then
        stop_ambient_loop
        tmux display-message "TTS Error: edge-tts failed"
        rm -f "$AUDIO_FILE"
        exit 1
    fi

    stop_ambient_loop
    afplay "$AUDIO_FILE" &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    rm -f "$PREP_PID_FILE"
    tmux display-message "TTS playing latest pane output (Ctrl+b p to stop)"
}

if is_playing; then
    stop_playback
else
    start_playback
fi
