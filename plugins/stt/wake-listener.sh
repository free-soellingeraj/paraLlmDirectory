#!/usr/bin/env bash
# wake-listener.sh - hands-free dictation for speak mode (Ctrl+b o).
# Runs whisper-stream (tiny.en) continuously while speak mode is on and
# watches its transcript for the configured phrases:
#
#   "start transcription"  -> chime, pause speak-mode playback, record mic
#   "stop transcription"   -> stop recording, transcribe (base.en full-file),
#                             strip the phrases, inject into the bound pane
#                             (no Enter — review before submitting), resume
#                             playback
#
# Started/stopped by toggle-stream.sh alongside the other speak-mode workers.
# The listener never presses Enter and dies with the mode.
#
# Usage: wake-listener.sh <pane_id> <spool_dir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANE_ID="${1:?usage: wake-listener.sh <pane_id> <spool_dir>}"
SPOOL="${2:?usage: wake-listener.sh <pane_id> <spool_dir>}"

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

# Single-word voice commands. "transcribe" toggles dictation; "repeat" re-runs
# the recap; "send" presses Enter in the bound pane.
STT_WAKE_TRANSCRIBE_WORD="${STT_WAKE_TRANSCRIBE_WORD:-transcribe}"
STT_WAKE_REPEAT_WORD="${STT_WAKE_REPEAT_WORD:-repeat}"
STT_WAKE_SEND_WORD="${STT_WAKE_SEND_WORD:-send}"
STT_WAKE_MODEL="${STT_WAKE_MODEL:-ggml-tiny.en.bin}"
STT_WAKE_STEP_MS="${STT_WAKE_STEP_MS:-2000}"
STT_WAKE_MAX_DICTATION="${STT_WAKE_MAX_DICTATION:-120}"
STT_WAKE_START_SOUND="${STT_WAKE_START_SOUND:-/System/Library/Sounds/Glass.aiff}"
STT_WAKE_STOP_SOUND="${STT_WAKE_STOP_SOUND:-/System/Library/Sounds/Bottle.aiff}"

WAKE_LOG="$SPOOL/wake.log"
STATE_FILE="$SPOOL/wake.state"
DICT_WAV="$SPOOL/dictation.wav"
STREAM_PID_FILE="$SPOOL/whisper-stream.pid"
REC_PID_FILE="$SPOOL/dictation-rec.pid"

log_lifecycle() {
    printf '%s  wake[%s]  %s\n' "$(date '+%F %T')" "$PANE_ID" "$*" \
        >> "$TTS_DIR/stream.log" 2>/dev/null || true
}

mode_active() {
    [[ "$(cat "$STREAM_PANE_FILE" 2>/dev/null)" == "$SAFE_PANE_ID" ]]
}

# Recursive signal to a process and its descendants (STOP/CONT/TERM). afplay
# runs as a child of the player loop, so pausing playback must reach it.
signal_tree() {
    local sig="$1" pid="$2" child
    [[ -z "$pid" ]] && return 0
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        signal_tree "$sig" "$child"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

# TERM, then KILL after a grace period — sox can wedge in CoreAudio teardown
# and ignore TERM (see toggle-stt.sh).
kill_recorder() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    kill "$pid" 2>/dev/null || return 0
    local n=0
    while kill -0 "$pid" 2>/dev/null; do
        n=$((n + 1))
        if [[ $n -gt 15 ]]; then
            kill -9 "$pid" 2>/dev/null || true
            break
        fi
        sleep 0.2
    done
}

chime() {
    [[ -f "$1" ]] && command -v afplay >/dev/null 2>&1 && afplay "$1" >/dev/null 2>&1 &
}

player_pid() { cat "$SPOOL/player.pid" 2>/dev/null; }
framing_pid() { cat "$SPOOL/framing.pid" 2>/dev/null; }

# SIGSTOP freezes the player loop, but the in-flight afplay keeps draining
# its CoreAudio buffer — the current sentence would play to the end while the
# user is dictating. Freeze the loop first (no new chunks start), then KILL
# the in-flight afplay children (SIGKILL works on stopped processes; TERM
# would stay pending until CONT). The interrupted sentence is skipped on
# resume. The framing worker is paused too so its "preparing" beeper stops.
pause_playback() {
    local pid child
    pid="$(player_pid)"
    if [[ -n "$pid" ]]; then
        signal_tree STOP "$pid"
        for child in $(pgrep -P "$pid" 2>/dev/null); do
            kill -9 "$child" 2>/dev/null || true
        done
    fi
    pid="$(framing_pid)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        signal_tree STOP "$pid"
    fi
}

resume_playback() {
    local pid
    pid="$(framing_pid)"
    [[ -n "$pid" ]] && signal_tree CONT "$pid"
    pid="$(player_pid)"
    [[ -n "$pid" ]] && signal_tree CONT "$pid"
}

normalize() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z ' | tr -s ' '
}

cleanup() {
    local pid
    pid="$(cat "$REC_PID_FILE" 2>/dev/null)"
    [[ -n "$pid" ]] && kill_recorder "$pid"
    pid="$(cat "$STREAM_PID_FILE" 2>/dev/null)"
    [[ -n "$pid" ]] && signal_tree TERM "$pid"
    # Never leave playback suspended.
    resume_playback
    rm -f "$STATE_FILE" "$REC_PID_FILE" "$STREAM_PID_FILE"
}
trap cleanup EXIT
trap 'cleanup; exit 0' TERM INT

# Wait for the mode file like the other workers (see toggle-stream start order).
tries=0
until mode_active; do
    tries=$((tries + 1))
    [[ "$tries" -gt 20 ]] && exit 0
    sleep 0.1
done

if ! command -v whisper-stream >/dev/null 2>&1; then
    log_lifecycle "skipped: whisper-stream not installed (brew install whisper-cpp)"
    exit 0
fi
if ! command -v rec >/dev/null 2>&1; then
    log_lifecycle "skipped: rec (sox) not installed"
    exit 0
fi

# tiny.en is enough for phrase spotting and much lighter than base.en.
MODEL_DIR="${PARA_LLM_ROOT:-$HOME/.para-llm-directory}/plugins/stt/models"
MODEL_PATH="$MODEL_DIR/$STT_WAKE_MODEL"
if [[ ! -f "$MODEL_PATH" ]]; then
    log_lifecycle "downloading wake model $STT_WAKE_MODEL"
    mkdir -p "$MODEL_DIR"
    if ! curl -sL -o "$MODEL_PATH" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$STT_WAKE_MODEL"; then
        rm -f "$MODEL_PATH"
        log_lifecycle "skipped: wake model download failed"
        exit 0
    fi
fi

# Stems are the first 8 chars of each command word, so "transcribe" also
# matches whisper renderings like "transcription"/"transcribed".
stem8() {
    local n
    n="$(normalize "$1")"
    printf '%s' "${n:0:8}"
}
TRANSCRIBE_STEM="$(stem8 "$STT_WAKE_TRANSCRIBE_WORD")"
REPEAT_STEM="$(stem8 "$STT_WAKE_REPEAT_WORD")"
SEND_STEM="$(stem8 "$STT_WAKE_SEND_WORD")"

# True while the player has an afplay in flight — i.e., TTS audio is coming
# out of the speakers, which the mic may hear (feedback).
player_speaking() {
    local pid
    pid="$(player_pid)"
    [[ -n "$pid" ]] && pgrep -P "$pid" -x afplay >/dev/null 2>&1
}

# A command fires when a SHORT utterance contains a word starting with the
# stem — word-prefix, not substring, so "send" never matches inside "ascend".
# Modes:
#   normal — <=3 words containing the stem; while TTS audio is in flight
#            (mic leak risk) exactly one word.
#   end    — ending a dictation: the stop word often lands in the SAME
#            whisper segment as the last dictated words ("...make it purple
#            transcribe"), so require the utterance to END with the stem
#            (<=6 words). A sentence that merely mentions transcription
#            mid-utterance stays content.
matches_word() {
    local line="$1" stem="$2" mode="${3:-normal}"
    [[ -n "$stem" && ${#stem} -ge 3 ]] || return 1
    local count=0 found=1 w last=""
    for w in $line; do
        count=$((count + 1))
        last="$w"
        [[ "$w" == "$stem"* ]] && found=0
    done
    if [[ "$mode" == "end" ]]; then
        [[ "$last" == "$stem"* && "$count" -le 6 ]]
    elif player_speaking; then
        [[ "$found" -eq 0 && "$count" -eq 1 ]]
    else
        [[ "$found" -eq 0 && "$count" -le 3 ]]
    fi
}

: > "$WAKE_LOG"
whisper-stream -m "$MODEL_PATH" -t 4 --step "$STT_WAKE_STEP_MS" --length 6000 \
    -f "$WAKE_LOG" >/dev/null 2>> "$SPOOL/error.log" &
echo "$!" > "$STREAM_PID_FILE"
echo "listening" > "$STATE_FILE"
log_lifecycle "listening for '$STT_WAKE_TRANSCRIBE_WORD' / '$STT_WAKE_REPEAT_WORD' / '$STT_WAKE_SEND_WORD'"

state="listening"
dict_started=0
dict_ended=0
# The word that just triggered lingers in whisper's ~6s sliding window and
# re-appears in the next segment(s). Until a line WITHOUT that stem arrives,
# the same command must not fire again — otherwise saying "transcribe" starts
# dictation and its own echo immediately ends it.
echo_stem=""

line_has_stem() {
    local line="$1" stem="$2" w
    [[ -n "$stem" ]] || return 1
    for w in $line; do
        [[ "$w" == "$stem"* ]] && return 0
    done
    return 1
}

begin_dictation() {
    state="dictating"
    echo "dictating" > "$STATE_FILE"
    dict_started=$SECONDS
    pause_playback
    chime "$STT_WAKE_START_SOUND"
    rm -f "$DICT_WAV"
    rec -b 16 -c 1 -r 16000 "$DICT_WAV" 2>"$SPOOL/dictation-rec.log" &
    echo "$!" > "$REC_PID_FILE"
    tmux display-message -t "$PANE_ID" "🎤 Dictating… say '$STT_WAKE_TRANSCRIBE_WORD' to finish" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
    log_lifecycle "dictation started"
}

end_dictation() {
    state="listening"
    dict_ended=$SECONDS
    echo "listening" > "$STATE_FILE"
    local rec_pid
    rec_pid="$(cat "$REC_PID_FILE" 2>/dev/null)"
    [[ -n "$rec_pid" ]] && kill_recorder "$rec_pid"
    rm -f "$REC_PID_FILE"
    chime "$STT_WAKE_STOP_SOUND"

    local text=""
    local size
    size="$(stat -f%z "$DICT_WAV" 2>/dev/null || stat -c%s "$DICT_WAV" 2>/dev/null || echo 0)"
    if [[ "$size" -gt 1000 ]]; then
        # Silence guard (see toggle-stt.sh): whisper hallucinates on silence.
        local rms ok=1
        if command -v sox >/dev/null 2>&1; then
            rms="$(sox "$DICT_WAV" -n stat 2>&1 | awk '/RMS[[:space:]]+amplitude/ {print $NF; exit}')"
            if [[ -n "$rms" ]] && awk -v r="$rms" 'BEGIN { exit !(r+0 < 0.003) }'; then
                ok=0
            fi
        fi
        if [[ "$ok" == "1" ]]; then
            text="$("$SCRIPT_DIR/transcribe.sh" "$DICT_WAV" 2>/dev/null || true)"
        fi
    fi
    rm -f "$DICT_WAV"

    if [[ -n "$text" ]]; then
        # The stop phrase lands in the recording tail (and the start phrase
        # occasionally in the head) — strip them from the edges.
        text="$(python3 - "$text" "$STT_WAKE_TRANSCRIBE_WORD" "$STT_WAKE_TRANSCRIBE_WORD" <<'PY'
import re, sys
text, start, stop = sys.argv[1], sys.argv[2], sys.argv[3]

# Strip the toggle word from the transcript edges by STEM (first 8 chars of
# the word, so transcribe/transcription/transcribed all match), tolerating a
# courtesy "start/stop" said out of habit. The tail rule requires whitespace
# before the stem so the preceding sentence keeps its own punctuation.
def clipped_core(phrase):
    words = phrase.split()
    stems = [re.escape(w[:8]) for w in words if len(w) >= 6]
    shorts = [re.escape(w) for w in words if len(w) < 6]
    if not stems:
        return None
    core = r"(?:%s)\w*" % "|".join(stems)
    # Habit tolerance: "stop transcribe." at the tail should strip fully even
    # though the command word is just "transcribe".
    shorts = shorts or ["start", "stop", "begin", "end"]
    opt = r"(?:(?:%s)[\s.,!?]+)?" % "|".join(shorts)
    return opt + core

head = clipped_core(start)
tail = clipped_core(stop)
if head:
    text = re.sub(r"(?i)^[\s.,!?]*" + head + r"[\s.,!?]*", " ", text)
if tail:
    text = re.sub(r"(?i)\s+" + tail + r"[\s.,!?]*$", "", text)
print(text.strip())
PY
)"
    fi

    resume_playback
    tmux refresh-client -S 2>/dev/null || true

    if [[ -z "$text" ]]; then
        tmux display-message -t "$PANE_ID" "STT: no speech detected" 2>/dev/null || true
        log_lifecycle "dictation ended: no speech"
        return 0
    fi

    tmux send-keys -t "$PANE_ID" -l "$text" 2>/dev/null || true
    local preview="$text"
    [[ ${#preview} -gt 60 ]] && preview="${preview:0:60}..."
    tmux display-message -t "$PANE_ID" "Transcribed: $preview" 2>/dev/null || true
    log_lifecycle "dictation injected: ${#text} chars"
}

# "repeat that": run the recap routine again (the speak-mode equivalent of
# Ctrl+b p) — scan back, summarize, speak, then resume streaming. Plays
# through the mode's own audio queue, so no playback-slot conflict.
do_repeat() {
    local fpid
    fpid="$(framing_pid)"
    if [[ -n "$fpid" ]] && kill -0 "$fpid" 2>/dev/null; then
        log_lifecycle "repeat-that ignored: recap already running"
        return 0
    fi
    log_lifecycle "repeat-that: recap requested"
    chime "$STT_WAKE_START_SOUND"
    touch "$SPOOL/framing.lock"
    nohup "$SCRIPT_DIR/../tts/stream-framing.sh" "$PANE_ID" "$SPOOL" >/dev/null 2>&1 &
    echo "$!" > "$SPOOL/framing.pid"
    tmux display-message -t "$PANE_ID" "🔁 Recapping…" 2>/dev/null || true
}

# "send that": press Enter in the bound pane — submits whatever the earlier
# dictation left in the input box.
do_send() {
    log_lifecycle "send-that: Enter sent"
    chime "$STT_WAKE_STOP_SOUND"
    tmux send-keys -t "$PANE_ID" Enter 2>/dev/null || true
    tmux display-message -t "$PANE_ID" "📨 Sent" 2>/dev/null || true
}

# Follow the whisper-stream transcript. read -t keeps the loop ticking so the
# max-dictation timeout and mode checks run even when nobody is speaking.
# Matching uses the last two lines joined, so a phrase split across two
# whisper segments still lands.
exec 3< <(tail -n 0 -F "$WAKE_LOG" 2>/dev/null)

while mode_active; do
    if read -t 1 -u 3 -r line; then
        norm_line="$(normalize "$line")"
        # The triggered word has left the window once a line arrives without it.
        if [[ -n "$echo_stem" ]] && ! line_has_stem "$norm_line" "$echo_stem"; then
            echo_stem=""
        fi
        if [[ "$state" == "listening" ]]; then
            # The dictation cooldown only guards the transcribe re-trigger
            # (its audio tail lingers in whisper's window) — "send" spoken a
            # couple of seconds after stopping must go straight through.
            if [[ "$echo_stem" != "$TRANSCRIBE_STEM" ]] \
                && (( SECONDS - dict_ended >= 3 )) \
                && matches_word "$norm_line" "$TRANSCRIBE_STEM"; then
                log_lifecycle "transcribe trigger: '$line'"
                begin_dictation
                echo_stem="$TRANSCRIBE_STEM"
            elif [[ "$echo_stem" != "$REPEAT_STEM" ]] \
                && matches_word "$norm_line" "$REPEAT_STEM"; then
                log_lifecycle "repeat trigger: '$line'"
                do_repeat
                echo_stem="$REPEAT_STEM"
            elif [[ "$echo_stem" != "$SEND_STEM" ]] \
                && matches_word "$norm_line" "$SEND_STEM"; then
                log_lifecycle "send trigger: '$line'"
                do_send
                echo_stem="$SEND_STEM"
            fi
        else
            if [[ "$echo_stem" != "$TRANSCRIBE_STEM" ]] \
                && matches_word "$norm_line" "$TRANSCRIBE_STEM" end; then
                log_lifecycle "transcribe-end trigger: '$line'"
                end_dictation
                echo_stem="$TRANSCRIBE_STEM"
            fi
        fi
    fi
    if [[ "$state" == "dictating" && "$STT_WAKE_MAX_DICTATION" != "0" ]] \
        && (( SECONDS - dict_started > STT_WAKE_MAX_DICTATION )); then
        log_lifecycle "dictation timeout after ${STT_WAKE_MAX_DICTATION}s"
        end_dictation
    fi
    # If whisper-stream died (mic conflict, crash), restart it once per tick.
    spid="$(cat "$STREAM_PID_FILE" 2>/dev/null)"
    if [[ -n "$spid" ]] && ! kill -0 "$spid" 2>/dev/null; then
        log_lifecycle "whisper-stream died; restarting"
        whisper-stream -m "$MODEL_PATH" -t 4 --step "$STT_WAKE_STEP_MS" --length 6000 \
            -f "$WAKE_LOG" >/dev/null 2>> "$SPOOL/error.log" &
        echo "$!" > "$STREAM_PID_FILE"
    fi
done

exit 0
