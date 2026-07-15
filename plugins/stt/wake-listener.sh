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
STT_WAKE_WINDOW_WORD="${STT_WAKE_WINDOW_WORD:-window}"
# Playback transport + input clearing.
STT_WAKE_PAUSE_WORD="${STT_WAKE_PAUSE_WORD:-pause}"
STT_WAKE_PLAY_WORD="${STT_WAKE_PLAY_WORD:-play}"
STT_WAKE_FORWARD_WORD="${STT_WAKE_FORWARD_WORD:-forward}"
STT_WAKE_REWIND_WORD="${STT_WAKE_REWIND_WORD:-rewind}"
STT_WAKE_CLEAR_WORD="${STT_WAKE_CLEAR_WORD:-text box}"
# Every accepted command clicks; every failed action buzzes.
STT_WAKE_ACK_SOUND="${STT_WAKE_ACK_SOUND-/System/Library/Sounds/Pop.aiff}"
STT_WAKE_FAIL_SOUND="${STT_WAKE_FAIL_SOUND-/System/Library/Sounds/Basso.aiff}"
STT_WAKE_MODEL="${STT_WAKE_MODEL:-ggml-tiny.en.bin}"
STT_WAKE_STEP_MS="${STT_WAKE_STEP_MS:-2000}"
STT_WAKE_MAX_DICTATION="${STT_WAKE_MAX_DICTATION:-120}"

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
# Whisper regularly mishears "transcribe" as "subscribe" (observed in real
# dictations) — accept it as an alias for the toggle word.
TRANSCRIBE_ALT_STEM="subscrib"

matches_transcribe() {
    matches_word "$1" "$TRANSCRIBE_STEM" "${2:-normal}" \
        || matches_word "$1" "$TRANSCRIBE_ALT_STEM" "${2:-normal}"
}
REPEAT_STEM="$(stem8 "$STT_WAKE_REPEAT_WORD")"
SEND_STEM="$(stem8 "$STT_WAKE_SEND_WORD")"
WINDOW_STEM="$(stem8 "$STT_WAKE_WINDOW_WORD")"
PAUSE_STEM="$(stem8 "$STT_WAKE_PAUSE_WORD")"
PLAY_STEM="$(stem8 "$STT_WAKE_PLAY_WORD")"
FORWARD_STEM="$(stem8 "$STT_WAKE_FORWARD_WORD")"
REWIND_STEM="$(stem8 "$STT_WAKE_REWIND_WORD")"
CLEAR_STEM="$(stem8 "${STT_WAKE_CLEAR_WORD%% *}")"
CLEAR_NORM="$(normalize "$STT_WAKE_CLEAR_WORD")"

# Multi-word command ("text box"): contains-match on a short utterance.
matches_clear() {
    local line="$1" count
    [[ "$line" == *"$CLEAR_NORM"* ]] || return 1
    count="$(printf '%s' "$line" | wc -w | tr -d ' ')"
    [[ "$count" -le 4 ]]
}

ack() { chime "$STT_WAKE_ACK_SOUND"; }
buzz() { chime "$STT_WAKE_FAIL_SOUND"; }

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
        # Commands are spoken as lone words; <=2 tolerates a filler ("uh
        # send") but keeps fragments of continuous speech from triggering.
        [[ "$found" -eq 0 && "$count" -le 2 ]]
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
    ack
    rm -f "$DICT_WAV"
    rec -b 16 -c 1 -r 16000 "$DICT_WAV" 2>"$SPOOL/dictation-rec.log" &
    echo "$!" > "$REC_PID_FILE"
    tmux display-message -t "$PANE_ID" "🎤 Dictating… say '$STT_WAKE_TRANSCRIBE_WORD' to finish" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
    log_lifecycle "dictation started"
}

end_dictation() {
    local stop_word="${1:-$STT_WAKE_TRANSCRIBE_WORD}"
    INJECTED=0
    state="listening"
    dict_ended=$SECONDS
    echo "listening" > "$STATE_FILE"
    local rec_pid
    rec_pid="$(cat "$REC_PID_FILE" 2>/dev/null)"
    [[ -n "$rec_pid" ]] && kill_recorder "$rec_pid"
    rm -f "$REC_PID_FILE"

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
        text="$(python3 - "$text" "$STT_WAKE_TRANSCRIBE_WORD" "$stop_word" <<'PY'
import re, sys
text, start, stop = sys.argv[1], sys.argv[2], sys.argv[3]

# Strip the toggle word from the transcript edges by STEM (first 8 chars of
# the word, so transcribe/transcription/transcribed all match), tolerating a
# courtesy "start/stop" said out of habit. The tail rule requires whitespace
# before the stem so the preceding sentence keeps its own punctuation.
def clipped_core(phrase):
    words = phrase.split()
    stems = [re.escape(w[:8]) for w in words if len(w) >= 6]
    if any(s.startswith("transcri") for s in stems):
        stems.append("subscrib")  # common whisper mishearing
    shorts = [re.escape(w) for w in words if len(w) < 6]
    if stems:
        core = r"(?:%s)\w*" % "|".join(stems)
    elif words:
        # Short command word ("send"): exact-word match, no suffix expansion.
        core = r"(?:%s)\b" % "|".join(re.escape(w) for w in words)
        shorts = []
    else:
        return None
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

    # Respect an explicit user pause: dictation ending must not unpause.
    if [[ "$PAUSED" != "1" ]]; then
        resume_playback
    fi
    tmux refresh-client -S 2>/dev/null || true

    if [[ -z "$text" ]]; then
        tmux display-message -t "$PANE_ID" "STT: no speech detected" 2>/dev/null || true
        log_lifecycle "dictation ended: no speech"
        buzz
        return 0
    fi

    tmux send-keys -t "$PANE_ID" -l "$text" 2>/dev/null && INJECTED=1
    if [[ "$INJECTED" == "1" ]]; then ack; else buzz; fi
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
        log_lifecycle "repeat ignored: recap already running"
        buzz
        return 0
    fi
    log_lifecycle "repeat: recap requested"
    ack
    touch "$SPOOL/framing.lock"
    nohup "$SCRIPT_DIR/../tts/stream-framing.sh" "$PANE_ID" "$SPOOL" >/dev/null 2>&1 &
    echo "$!" > "$SPOOL/framing.pid"
    tmux display-message -t "$PANE_ID" "🔁 Recapping…" 2>/dev/null || true
}

# "send": press Enter in the bound pane — submits whatever the earlier
# dictation left in the input box.
do_send() {
    if tmux send-keys -t "$PANE_ID" Enter 2>/dev/null; then
        log_lifecycle "send: Enter sent"
        ack
        tmux display-message -t "$PANE_ID" "📨 Sent" 2>/dev/null || true
    else
        log_lifecycle "send FAILED: send-keys error"
        buzz
    fi
}

# "window": move the speak-mode binding (and the purple) onward — next window
# in the bound pane's session, or next pane when there's only one window
# (command-center layout). Re-binding goes through toggle-stream's move path,
# which also replaces this listener; the recap frames the new pane.
do_window() {
    local sess wins target=""
    sess="$(tmux display-message -pt "$PANE_ID" '#{session_name}' 2>/dev/null)"
    if [[ -z "$sess" ]]; then
        log_lifecycle "window FAILED: no session for $PANE_ID"
        buzz
        return 0
    fi
    wins="$(tmux list-windows -t "$sess" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$wins" -gt 1 ]]; then
        if ! tmux select-window -t "$sess:+" 2>/dev/null; then
            log_lifecycle "window FAILED: select-window"
            buzz
            return 0
        fi
        target="$(tmux display-message -pt "$sess:" '#{pane_id}' 2>/dev/null)"
    else
        # Single window: cycle to the pane after the bound one, wrapping.
        local panes=() p i=0 idx=-1
        while IFS= read -r p; do
            panes+=("$p")
            [[ "$p" == "$PANE_ID" ]] && idx=$i
            i=$((i + 1))
        done < <(tmux list-panes -t "$sess:" -F '#{pane_id}' 2>/dev/null)
        if [[ "$idx" -ge 0 && "${#panes[@]}" -gt 1 ]]; then
            target="${panes[$(( (idx + 1) % ${#panes[@]} ))]}"
            tmux select-pane -t "$target" 2>/dev/null || true
        fi
    fi
    if [[ -z "$target" || "$target" == "$PANE_ID" ]]; then
        log_lifecycle "window FAILED: no other pane/window to move to"
        buzz
        return 0
    fi
    log_lifecycle "window: moving speak mode to $target"
    ack
    # Announce where we landed — env name if the pane lives in an env,
    # else the tmux window name.
    local tpath tlabel
    tpath="$(tmux display-message -pt "$target" '#{pane_current_path}' 2>/dev/null)"
    case "$tpath" in
        */envs/*) tlabel="${tpath#*/envs/}"; tlabel="${tlabel%%/*}" ;;
        *)        tlabel="$(tmux display-message -pt "$target" '#{window_name}' 2>/dev/null)" ;;
    esac
    if [[ -n "$tlabel" ]] && command -v say >/dev/null 2>&1; then
        ( say "$tlabel" >/dev/null 2>&1 & )
    fi
    nohup "$SCRIPT_DIR/../tts/toggle-stream.sh" "$target" >/dev/null 2>&1 &
}

PAUSED=0
INJECTED=0

# "send" while dictating: stricter than the transcribe-end rule — an utterance
# of at most TWO words ending with the send word ("send." / "and send"), so
# dictated prose that merely mentions sending stays content.
ends_with_send() {
    local line="$1" count=0 last="" w
    [[ -n "$SEND_STEM" ]] || return 1
    for w in $line; do
        count=$((count + 1))
        last="$w"
    done
    [[ "$last" == "$SEND_STEM"* && "$count" -le 2 ]]
}

kill_inflight_afplay() {
    local pid child
    pid="$(player_pid)"
    [[ -n "$pid" ]] || return 0
    for child in $(pgrep -P "$pid" -x afplay 2>/dev/null); do
        kill -9 "$child" 2>/dev/null || true
    done
}

# "pause": stop talking NOW and stay quiet until "play". Queued audio ages out
# via the stale-skip, so resume lands on current content, not the backlog.
do_pause() {
    if [[ "$PAUSED" == "1" ]]; then
        buzz
        return 0
    fi
    PAUSED=1
    touch "$SPOOL/paused"
    pause_playback
    ack
    log_lifecycle "pause"
    tmux display-message -t "$PANE_ID" "⏸ Paused — say '$STT_WAKE_PLAY_WORD' to resume" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

do_play() {
    if [[ "$PAUSED" != "1" ]]; then
        buzz
        return 0
    fi
    PAUSED=0
    rm -f "$SPOOL/paused"
    resume_playback
    ack
    log_lifecycle "play"
    tmux refresh-client -S 2>/dev/null || true
}

# Seeks are chunk-based (~1 chunk ≈ 10-15s of speech): the listener writes a
# command for the player loop and kills the in-flight afplay so it reacts now.
do_forward() {
    echo "skip 1" > "$SPOOL/player.cmd"
    kill_inflight_afplay
    ack
    log_lifecycle "forward"
}

do_rewind() {
    echo "back 2" > "$SPOOL/player.cmd"
    kill_inflight_afplay
    ack
    log_lifecycle "rewind"
}

# "text box": clear the dictated blob from Claude Code's input. A single
# Ctrl+C clears a non-empty input box (and merely warns on an empty one —
# never sent twice, so it cannot exit the REPL).
do_clear() {
    if tmux send-keys -t "$PANE_ID" C-c 2>/dev/null; then
        ack
        log_lifecycle "clear: input box cleared"
        tmux display-message -t "$PANE_ID" "🗑 Input cleared" 2>/dev/null || true
    else
        buzz
        log_lifecycle "clear FAILED: send-keys error"
    fi
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
                && matches_transcribe "$norm_line"; then
                log_lifecycle "transcribe trigger: '$line'"
                begin_dictation
                echo_stem="$TRANSCRIBE_STEM"
            elif ! player_speaking && [[ "$echo_stem" != "$REPEAT_STEM" ]] \
                && matches_word "$norm_line" "$REPEAT_STEM"; then
                log_lifecycle "repeat trigger: '$line'"
                do_repeat
                echo_stem="$REPEAT_STEM"
            elif ! player_speaking && [[ "$echo_stem" != "$SEND_STEM" ]] \
                && matches_word "$norm_line" "$SEND_STEM"; then
                log_lifecycle "send trigger: '$line'"
                do_send
                echo_stem="$SEND_STEM"
            elif ! player_speaking && [[ "$echo_stem" != "$WINDOW_STEM" ]] \
                && matches_word "$norm_line" "$WINDOW_STEM"; then
                log_lifecycle "window trigger: '$line'"
                do_window
                echo_stem="$WINDOW_STEM"
            elif [[ "$echo_stem" != "$PAUSE_STEM" ]] \
                && matches_word "$norm_line" "$PAUSE_STEM"; then
                log_lifecycle "pause trigger: '$line'"
                do_pause
                echo_stem="$PAUSE_STEM"
            elif ! player_speaking && [[ "$echo_stem" != "$PLAY_STEM" ]] \
                && matches_word "$norm_line" "$PLAY_STEM"; then
                log_lifecycle "play trigger: '$line'"
                do_play
                echo_stem="$PLAY_STEM"
            elif [[ "$echo_stem" != "$FORWARD_STEM" ]] \
                && matches_word "$norm_line" "$FORWARD_STEM"; then
                log_lifecycle "forward trigger: '$line'"
                do_forward
                echo_stem="$FORWARD_STEM"
            elif [[ "$echo_stem" != "$REWIND_STEM" ]] \
                && matches_word "$norm_line" "$REWIND_STEM"; then
                log_lifecycle "rewind trigger: '$line'"
                do_rewind
                echo_stem="$REWIND_STEM"
            elif ! player_speaking && [[ "$echo_stem" != "$CLEAR_STEM" ]] \
                && matches_clear "$norm_line"; then
                log_lifecycle "clear trigger: '$line'"
                do_clear
                echo_stem="$CLEAR_STEM"
            fi
        else
            if [[ "$echo_stem" != "$TRANSCRIBE_STEM" ]] \
                && matches_transcribe "$norm_line" end; then
                log_lifecycle "transcribe-end trigger: '$line'"
                end_dictation
                echo_stem="$TRANSCRIBE_STEM"
            elif [[ "$echo_stem" != "$SEND_STEM" ]] \
                && ends_with_send "$norm_line"; then
                # "send" closes the take AND submits — no second "transcribe".
                log_lifecycle "send-end trigger: '$line'"
                end_dictation "$STT_WAKE_SEND_WORD"
                if [[ "$INJECTED" == "1" ]]; then
                    sleep 0.4   # let the injected text settle in the input box
                    do_send
                fi
                echo_stem="$SEND_STEM"
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
