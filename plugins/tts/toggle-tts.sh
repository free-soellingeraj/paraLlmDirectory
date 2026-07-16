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
TTS_SUMMARIZER_BACKEND="${TTS_SUMMARIZER_BACKEND:-codex}"
# How long (seconds) an agent-authored script (voice-script.sh) stays eligible
# for direct playback before it's treated as stale and we fall back to live
# capture + summarize. 0 = never expires.
TTS_AUTHORED_MAX_AGE="${TTS_AUTHORED_MAX_AGE:-900}"

PANE_ID="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
PANE_PATH="$(tmux display-message -p -t "$PANE_ID" '#{pane_current_path}' 2>/dev/null || pwd)"
SAFE_PANE_ID="${PANE_ID#%}"
PID_FILE="$TTS_DIR/$SAFE_PANE_ID.pid"
PREP_PID_FILE="$TTS_DIR/$SAFE_PANE_ID.prep.pid"
AMBIENT_PID_FILE="$TTS_DIR/$SAFE_PANE_ID.ambient.pid"
PROGRESS_PID_FILE="$TTS_DIR/$SAFE_PANE_ID.progress.pid"
PHASE_FILE="$TTS_DIR/$SAFE_PANE_ID.phase"
PROGRESS_LOG="$TTS_DIR/$SAFE_PANE_ID.progress.log"
ERROR_LOG="$TTS_DIR/$SAFE_PANE_ID.error.log"
TEXT_FILE="$TTS_DIR/$SAFE_PANE_ID.txt"
SPEECH_FILE="$TTS_DIR/$SAFE_PANE_ID.speech.txt"
# Speakable script pre-authored by the coding agent (via voice-script.sh). When
# present and fresh it is played directly, skipping capture + LLM summarize.
AUTHORED_FILE="$TTS_DIR/$SAFE_PANE_ID.authored.txt"
AUDIO_FILE="$TTS_DIR/$SAFE_PANE_ID.mp3"
AUDIO_DIR="$TTS_DIR/$SAFE_PANE_ID.audio"
PLAYLIST_FILE="$TTS_DIR/$SAFE_PANE_ID.audio-list"
ACTIVE_FILE="$TTS_DIR/active.pane"
TOGGLE_LOCK="$TTS_DIR/$SAFE_PANE_ID.toggle.lock"

TTS_AMBIENT_SOUND_ENABLED="${TTS_AMBIENT_SOUND_ENABLED:-1}"
TTS_AMBIENT_SOUND_INTERVAL="${TTS_AMBIENT_SOUND_INTERVAL:-1}"
TTS_AMBIENT_SOUND="${TTS_AMBIENT_SOUND:-/System/Library/Sounds/Tink.aiff}"
# Safety net: never let the "preparing" beep loop longer than this, even if a
# downstream step hangs. 0 disables the cap.
TTS_AMBIENT_MAX_SECONDS="${TTS_AMBIENT_MAX_SECONDS:-120}"
# Hard cap on edge-tts audio synthesis (a stalled network call can hang here).
# 0 disables the cap.
TTS_SYNTH_TIMEOUT="${TTS_SYNTH_TIMEOUT:-60}"
# Maximum characters per edge-tts request. Long requests can stall after writing
# partial audio; smaller sentence-based chunks are more reliable.
TTS_SYNTH_CHARS="${TTS_SYNTH_CHARS:-180}"
# Live progress indicator: shows the current prep stage and how long it has
# been running, so a hang is visible (and where). 0 disables it.
TTS_PROGRESS_ENABLED="${TTS_PROGRESS_ENABLED:-1}"
TTS_PROGRESS_INTERVAL="${TTS_PROGRESS_INTERVAL:-1}"

# Shared helpers: TIMEOUT_CMD, kill_tree, stop_playback_for_pane,
# split_speech_for_synthesis, synthesize_chunk, synthesize_local_chunk.
source "$SCRIPT_DIR/tts-lib.sh"

# Speak mode (Ctrl+b o) owns the audio channel while active — a one-shot
# playback would fight it for the playback slot and talk over it.
STREAM_PANE_FILE="$TTS_DIR/stream.pane"
if [[ -s "$STREAM_PANE_FILE" ]]; then
    stream_owner="$(cat "$STREAM_PANE_FILE" 2>/dev/null)"
    tmux display-message "TTS: speak mode active on %$stream_owner — Ctrl+b o to stop it first"
    exit 0
fi

# Serialize concurrent prefix-p presses for this pane. The mkdir is atomic, so
# only one instance at a time can decide start-vs-stop and claim the prep slot.
acquire_toggle_lock() {
    local tries=0
    while ! mkdir "$TOGGLE_LOCK" 2>/dev/null; do
        # Break a lock left behind by a crashed instance.
        local holder
        holder="$(cat "$TOGGLE_LOCK/pid" 2>/dev/null)"
        if [[ -z "$holder" ]] || ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$TOGGLE_LOCK" 2>/dev/null
            continue
        fi
        tries=$((tries + 1))
        [[ "$tries" -gt 100 ]] && break   # ~5s safety valve
        sleep 0.05
    done
    echo "$$" > "$TOGGLE_LOCK/pid" 2>/dev/null || true
}

release_toggle_lock() {
    rm -rf "$TOGGLE_LOCK" 2>/dev/null || true
}

# True only while this instance still owns the prep slot. A second press that
# stops/steals us removes PREP_PID_FILE, so we can bail before playing.
still_owner() {
    [[ -f "$PREP_PID_FILE" ]] && [[ "$(cat "$PREP_PID_FILE" 2>/dev/null)" == "$$" ]]
}

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
        kill_tree "$pid"
    fi
    prep_pid="$(cat "$PREP_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$prep_pid" && "$prep_pid" != "$$" ]]; then
        kill_tree "$prep_pid"
    fi
    rm -f "$PID_FILE"
    rm -f "$PREP_PID_FILE"
    rm -f "$AUDIO_FILE"
    rm -f "$PLAYLIST_FILE"
    rm -rf "$AUDIO_DIR"
    stop_ambient_loop
    stop_progress_loop
    release_playback_slot
    tmux display-message "TTS stopped"
}

acquire_playback_slot() {
    if [[ -f "$ACTIVE_FILE" ]]; then
        local other
        other="$(cat "$ACTIVE_FILE" 2>/dev/null)"
        if [[ -n "$other" && "$other" != "$SAFE_PANE_ID" ]]; then
            stop_playback_for_pane "$other"
            tmux display-message "TTS: stole playback from pane %$other"
        fi
    fi
    echo "$SAFE_PANE_ID" > "$ACTIVE_FILE"
}

release_playback_slot() {
    if [[ -f "$ACTIVE_FILE" ]]; then
        local owner
        owner="$(cat "$ACTIVE_FILE" 2>/dev/null)"
        if [[ "$owner" == "$SAFE_PANE_ID" ]]; then
            rm -f "$ACTIVE_FILE"
        fi
    fi
}

stop_ambient_loop() {
    local ambient_pid
    ambient_pid="$(cat "$AMBIENT_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$ambient_pid" ]]; then
        kill "$ambient_pid" 2>/dev/null || true
    fi
    rm -f "$AMBIENT_PID_FILE"
}

# True if the agent-authored script exists, is non-empty, and is within the
# freshness window (so we don't speak a stale briefing from a previous task).
authored_is_fresh() {
    [[ -s "$AUTHORED_FILE" ]] || return 1
    [[ "$TTS_AUTHORED_MAX_AGE" == "0" ]] && return 0
    local now mtime age
    now="$(date +%s)"
    mtime="$(stat -f %m "$AUTHORED_FILE" 2>/dev/null || stat -c %Y "$AUTHORED_FILE" 2>/dev/null || echo 0)"
    age=$((now - mtime))
    [[ "$age" -le "$TTS_AUTHORED_MAX_AGE" ]]
}

# Record the current prep stage. The live indicator reads PHASE_FILE; the log
# keeps a timestamped trail so you can see, after the fact, where it stalled.
set_phase() {
    local phase="$1"
    echo "$phase" > "$PHASE_FILE" 2>/dev/null || true
    printf '%s  %s\n' "$(date '+%H:%M:%S')" "$phase" >> "$PROGRESS_LOG" 2>/dev/null || true
}

log_error() {
    printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >> "$ERROR_LOG" 2>/dev/null || true
}

# Background loop that keeps the tmux status line showing the current stage and
# how long it has been running, e.g. "TTS: generating audio (12s)". Per-stage
# timer resets whenever set_phase changes PHASE_FILE, so a hang is easy to spot.
start_progress_loop() {
    if [[ "$TTS_PROGRESS_ENABLED" == "0" ]]; then
        return 0
    fi
    stop_progress_loop
    local interval="$TTS_PROGRESS_INTERVAL"
    (
        local last="" phase phase_start=0 elapsed
        SECONDS=0
        while true; do
            phase="$(cat "$PHASE_FILE" 2>/dev/null || echo "starting")"
            if [[ "$phase" != "$last" ]]; then
                last="$phase"
                phase_start=$SECONDS
            fi
            elapsed=$((SECONDS - phase_start))
            tmux display-message -t "$PANE_ID" \
                "TTS: $phase (${elapsed}s) — Ctrl+b p to stop" 2>/dev/null || true
            sleep "$interval"
        done
    ) &
    echo "$!" > "$PROGRESS_PID_FILE"
}

stop_progress_loop() {
    local progress_pid
    progress_pid="$(cat "$PROGRESS_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$progress_pid" ]]; then
        kill "$progress_pid" 2>/dev/null || true
    fi
    rm -f "$PROGRESS_PID_FILE"
    rm -f "$PHASE_FILE"
}

cleanup_on_exit() {
    stop_ambient_loop
    stop_progress_loop
    release_toggle_lock
    # Only clear the prep marker if it's still ours — a stealing instance may
    # have already claimed it.
    still_owner && rm -f "$PREP_PID_FILE"
    if [[ ! -f "$PID_FILE" ]]; then
        # No live playback handed off — give up the slot so another pane can claim it.
        release_playback_slot
    fi
}

# On a real signal (e.g. another press killed us mid-prep) tear down and EXIT,
# so a killed prepping instance never resumes into afplay.
cleanup_on_signal() {
    stop_ambient_loop
    stop_progress_loop
    release_toggle_lock
    still_owner && rm -f "$PREP_PID_FILE"
    release_playback_slot
    exit 0
}
trap cleanup_on_exit EXIT
trap cleanup_on_signal TERM INT

start_ambient_loop() {
    if [[ "$TTS_AMBIENT_SOUND_ENABLED" == "0" ]]; then
        return 0
    fi
    if ! command -v afplay >/dev/null 2>&1 || [[ ! -f "$TTS_AMBIENT_SOUND" ]]; then
        return 0
    fi

    stop_ambient_loop
    local max_secs="$TTS_AMBIENT_MAX_SECONDS"
    (
        SECONDS=0
        while true; do
            afplay "$TTS_AMBIENT_SOUND" >/dev/null 2>&1 || true
            # Stop beeping after the cap even if prep never finishes, so a hung
            # downstream step can't beep indefinitely.
            if [[ "$max_secs" != "0" && "$SECONDS" -ge "$max_secs" ]]; then
                break
            fi
            sleep "$TTS_AMBIENT_SOUND_INTERVAL"
        done
    ) &
    echo "$!" > "$AMBIENT_PID_FILE"
}

synthesize_audio() {
    local input_file="$1"
    local output_file="$2"
    local chunk_dir="$TTS_DIR/$SAFE_PANE_ID.synth.$$"
    local synth_err="$TTS_DIR/$SAFE_PANE_ID.edge-tts.err"
    local chunk chunk_audio index=0 status

    rm -rf "$chunk_dir"
    mkdir -p "$chunk_dir"
    rm -rf "$AUDIO_DIR"
    mkdir -p "$AUDIO_DIR"
    : > "$PLAYLIST_FILE"
    if ! split_speech_for_synthesis "$input_file" "$chunk_dir" "$TTS_SYNTH_CHARS"; then
        log_error "failed to split speech for synthesis"
        rm -rf "$chunk_dir" "$synth_err" "$AUDIO_DIR" "$PLAYLIST_FILE"
        return 1
    fi

    for chunk in "$chunk_dir"/chunk-*.txt; do
        [[ -f "$chunk" ]] || continue
        index=$((index + 1))
        chunk_audio="$AUDIO_DIR/chunk-$(printf '%03d' "$index").mp3"
        set_phase "generating audio chunk $index"

        synthesize_chunk "$chunk" "$chunk_audio" "$synth_err"
        status=$?
        if [[ "$status" -ne 0 ]]; then
            log_error "edge-tts chunk $index failed with status $status; retrying once"
            sed 's/^/edge-tts: /' "$synth_err" >> "$ERROR_LOG" 2>/dev/null || true
            sleep 1
            rm -f "$chunk_audio"
            synthesize_chunk "$chunk" "$chunk_audio" "$synth_err"
            status=$?
        fi
        if [[ "$status" -ne 0 ]]; then
            log_error "edge-tts chunk $index retry failed with status $status; using local say fallback"
            sed 's/^/edge-tts: /' "$synth_err" >> "$ERROR_LOG" 2>/dev/null || true
            chunk_audio="$AUDIO_DIR/chunk-$(printf '%03d' "$index").aiff"
            set_phase "local audio chunk $index"
            if ! synthesize_local_chunk "$chunk" "$chunk_audio"; then
                log_error "local say fallback failed for chunk $index"
                rm -rf "$chunk_dir" "$synth_err" "$output_file" "$AUDIO_DIR" "$PLAYLIST_FILE"
                return 1
            fi
        fi
        if [[ ! -s "$chunk_audio" ]]; then
            log_error "audio chunk $index produced no audio"
            rm -rf "$chunk_dir" "$synth_err" "$output_file" "$AUDIO_DIR" "$PLAYLIST_FILE"
            return 1
        fi
        printf '%s\n' "$chunk_audio" >> "$PLAYLIST_FILE"
    done

    rm -rf "$chunk_dir" "$synth_err"
    : > "$output_file"
    [[ "$index" -gt 0 ]] && [[ -s "$PLAYLIST_FILE" ]]
}

start_playback() {
    # PREP_PID_FILE is already claimed under the toggle lock by the caller.
    acquire_playback_slot

    if ! command -v edge-tts >/dev/null 2>&1; then
        tmux display-message "TTS Error: edge-tts not found. Install with: pipx install edge-tts"
        exit 1
    fi
    if ! command -v afplay >/dev/null 2>&1; then
        tmux display-message "TTS Error: afplay not found"
        exit 1
    fi

    : > "$PROGRESS_LOG" 2>/dev/null || true
    : > "$ERROR_LOG" 2>/dev/null || true
    # Start the loop first: it calls stop_progress_loop (which clears PHASE_FILE),
    # so set_phase must come after, or the first stage label gets wiped.
    start_progress_loop

    if authored_is_fresh; then
        # The coding agent already wrote a speakable script for this pane via
        # voice-script.sh — play it directly, no capture or summarize needed.
        set_phase "using agent-authored script"
        cp "$AUTHORED_FILE" "$SPEECH_FILE"
        start_ambient_loop
    else
        set_phase "extracting pane text"
        "$SCRIPT_DIR/extract-latest.sh" "$PANE_ID" > "$TEXT_FILE"
        if [[ ! -s "$TEXT_FILE" ]]; then
            tmux display-message "TTS: no readable pane text found"
            exit 1
        fi

        start_ambient_loop
        cp "$TEXT_FILE" "$SPEECH_FILE"
        if [[ "$TTS_SUMMARIZE" != "0" ]]; then
            # Summarizer backend is decoupled from the pane's interactive REPL: the
            # only LLM summarizer is codex (claude -p was retired — see ADR-009), so
            # a Claude-Code pane no longer routes TTS through the metered claude -p.
            local backend="$TTS_SUMMARIZER_BACKEND"
            set_phase "summarizing via $backend"
            if ! "$SCRIPT_DIR/summarize-for-speech.sh" "$backend" "$TEXT_FILE" "$SPEECH_FILE" "$PANE_PATH" >/dev/null 2>&1; then
                cp "$TEXT_FILE" "$SPEECH_FILE"
                set_phase "summary unavailable, using raw text"
            fi
        fi
    fi

    # Bail out if a second press stopped/stole us while summarizing, so we
    # don't waste an audio synthesis and start an overlapping playback.
    if ! still_owner; then
        stop_ambient_loop
        exit 0
    fi

    rm -f "$AUDIO_FILE"
    if ! synthesize_audio "$SPEECH_FILE" "$AUDIO_FILE"; then
        stop_ambient_loop
        tmux display-message "TTS Error: edge-tts failed; see $ERROR_LOG"
        rm -f "$AUDIO_FILE"
        exit 1
    fi

    stop_ambient_loop

    # Final guard: if a stop arrived during synthesis, do not start playback.
    if ! still_owner; then
        rm -f "$AUDIO_FILE"
        exit 0
    fi

    set_phase "audio ready"
    set_phase "playing"
    stop_progress_loop
    (
        while IFS= read -r chunk_audio; do
            [[ -f "$chunk_audio" ]] || continue
            afplay "$chunk_audio" || exit $?
        done < "$PLAYLIST_FILE"
        rm -f "$PID_FILE" "$AUDIO_FILE" "$PLAYLIST_FILE"
        rm -rf "$AUDIO_DIR"
        release_playback_slot
    ) >> "$ERROR_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    rm -f "$PREP_PID_FILE"
    tmux display-message "TTS playing latest pane output (Ctrl+b p to stop)"
}

# Serialize the start-vs-stop decision so two quick prefix-p presses in the
# same pane can't both decide "start" and produce two offset playbacks.
acquire_toggle_lock
if is_playing; then
    release_toggle_lock
    stop_playback
else
    # Claim the prep slot atomically while still holding the lock, before any
    # slow work, so a second press sees us as already-preparing.
    echo "$$" > "$PREP_PID_FILE"
    release_toggle_lock
    start_playback
fi
