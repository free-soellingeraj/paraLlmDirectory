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
# "recap", not "repeat". The echo guard suppresses any command word the agent is
# currently narrating, and "repeat" is a word this project's own narration says
# constantly — so the command silently refused to fire exactly when you most
# wanted it. "recap" is not vocabulary the narration reaches for.
STT_WAKE_REPEAT_WORD="${STT_WAKE_REPEAT_WORD:-recap}"
# "cancel": clear the whole playback buffer; keep narrating new output.
STT_WAKE_CANCEL_WORD="${STT_WAKE_CANCEL_WORD:-cancel}"
# "repeat": say the current turn again from the start, verbatim — for when you
# simply missed it, or want it from the top mid-way through. Distinct from
# "recap", which is the zoomed-out briefing across several turns.
#
# NOTE, because this word has history: "repeat" was RENAMED to "recap" precisely
# because the mic echo guard drops any command word the narration is currently
# speaking, and narration says "repeat" often. Re-introducing it re-introduces
# that collision. Two mitigations: saying it twice ("repeat repeat") is a clean
# burst, which bypasses the echo guard by design; and STT_WAKE_REWIND_WORD
# ("rewind") is wired to the same action as a word narration rarely uses.
STT_WAKE_REPEAT_TURN_WORD="${STT_WAKE_REPEAT_TURN_WORD:-repeat}"
STT_WAKE_SEND_WORD="${STT_WAKE_SEND_WORD:-send}"
STT_WAKE_WINDOW_WORD="${STT_WAKE_WINDOW_WORD:-window}"
# Playback transport + input clearing.
STT_WAKE_PAUSE_WORD="${STT_WAKE_PAUSE_WORD:-pause}"
STT_WAKE_PLAY_WORD="${STT_WAKE_PLAY_WORD:-play}"
STT_WAKE_FORWARD_WORD="${STT_WAKE_FORWARD_WORD:-forward}"
STT_WAKE_REWIND_WORD="${STT_WAKE_REWIND_WORD:-rewind}"
STT_WAKE_CLEAR_WORD="${STT_WAKE_CLEAR_WORD:-text box}"
STT_WAKE_DIGEST_WORD="${STT_WAKE_DIGEST_WORD:-digest}"
STT_WAKE_DIAGNOSTIC_WORD="${STT_WAKE_DIAGNOSTIC_WORD:-diagnostic}"
# Every accepted command clicks; every failed action buzzes.
STT_WAKE_ACK_SOUND="${STT_WAKE_ACK_SOUND-/System/Library/Sounds/Pop.aiff}"
STT_WAKE_FAIL_SOUND="${STT_WAKE_FAIL_SOUND-/System/Library/Sounds/Basso.aiff}"
# "send" gets its own, more audible confirmation: Pop is too subtle to hear
# over in-flight narration, and "did it submit?" is the one signal that can't
# be missed (BUG-027).
STT_WAKE_SEND_SOUND="${STT_WAKE_SEND_SOUND-/System/Library/Sounds/Hero.aiff}"
# Dictation keeps its own distinct pair (user preference): Glass = mic open,
# Bottle = transcript landed.
STT_WAKE_START_SOUND="${STT_WAKE_START_SOUND:-/System/Library/Sounds/Glass.aiff}"
STT_WAKE_STOP_SOUND="${STT_WAKE_STOP_SOUND:-/System/Library/Sounds/Bottle.aiff}"
STT_WAKE_MODEL="${STT_WAKE_MODEL:-ggml-tiny.en.bin}"
# Lower = whisper transcribes more often = less lag between the spoken word
# and the tone, and short words ("send") are caught more reliably. 1500 was
# sluggish; 700 roughly halves the detection latency.
STT_WAKE_STEP_MS="${STT_WAKE_STEP_MS:-700}"
STT_WAKE_MAX_DICTATION="${STT_WAKE_MAX_DICTATION:-120}"
# How many words a line may hold and still have a trailing "send" close the
# take. Whisper's sliding window runs long during continuous speech, and the old
# cap of 12 silently rejected a perfectly clear "... Send." on a longer line.
STT_WAKE_SEND_END_MAX_WORDS="${STT_WAKE_SEND_END_MAX_WORDS:-20}"

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

# Volume for the acknowledgement, which competes with live narration. afplay's
# -v is a multiplier (1.0 = as recorded), and Pop.aiff is a short quiet click —
# at unity it simply disappears under speech. Observed: a "recap" acked at
# 14:10:27 while narration was playing, and the same command was said again 3s
# later, i.e. the tone fired and was not heard. The tone is the whole mechanism
# that stops commands being repeated, so it has to win against the voice.
STT_WAKE_ACK_VOLUME="${STT_WAKE_ACK_VOLUME:-2.5}"

chime() {
    local f="$1" vol="${2:-1}"
    [[ -f "$f" ]] && command -v afplay >/dev/null 2>&1 \
        && afplay -v "$vol" "$f" >/dev/null 2>&1 &
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
    # Bridge to the new tail->rewrite->speak loop (prototype): while this file
    # exists its player holds and interrupts the in-flight chunk.
    [[ -n "${SPEAKLOOP_PAUSE_FILE:-}" ]] && touch "$SPEAKLOOP_PAUSE_FILE" 2>/dev/null || true
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
    [[ -n "${SPEAKLOOP_PAUSE_FILE:-}" ]] && rm -f "$SPEAKLOOP_PAUSE_FILE" 2>/dev/null || true
    pid="$(framing_pid)"
    [[ -n "$pid" ]] && signal_tree CONT "$pid"
    pid="$(player_pid)"
    [[ -n "$pid" ]] && signal_tree CONT "$pid"
}

normalize() {
    # whisper-stream emits noise annotations — "[BLANK_AUDIO]", "[MUSIC
    # PLAYING]", "(clicking)" — that are metadata, not speech. Drop them
    # BEFORE word-counting: they inflate utterance length past the strict
    # while-speaking limits and can even trigger commands ("[MUSIC PLAYING]"
    # once matched "play").
    printf '%s' "$1" \
        | sed -E 's/\[[^][]*\]//g; s/\([^()]*\)//g; s/\*[^*]*\*//g' \
        | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z ' | tr -s ' '
}

# --- Mic health ---------------------------------------------------------------
# The diagnostic could report every worker alive, every queue empty and the
# speech service reachable while the microphone delivered nothing but silence,
# because nothing ever looked at whether AUDIO WAS ARRIVING. That failure has
# now cost three separate debugging sessions, each ending at the same one-line
# cause: macOS input volume sitting at 27.
#
# "Silence" is judged the way the command matcher judges it — by normalize(),
# which strips whisper's noise annotations. "[BLANK_AUDIO]" and "(birds
# chirping)" are NOT speech, and a run of them is exactly what a too-quiet mic
# produces. A person simply not talking looks the same, which is why the input
# volume is reported alongside rather than inferred from the silence.
STT_WAKE_MIN_INPUT_VOLUME="${STT_WAKE_MIN_INPUT_VOLUME:-40}"

input_volume() {
    command -v osascript >/dev/null 2>&1 || return 1
    osascript -e 'input volume of (get volume settings)' 2>/dev/null
}

# WHICH device the level belongs to. macOS stores input volume PER DEVICE, and
# that is the whole reason this problem kept coming back: raising the level on
# the MacBook mic did nothing the next time AirPods became the default input,
# because AirPods carries its own stored 27. Reporting a bare number sent three
# debugging sessions looking for something that was "resetting" a setting that
# was never reset — a different device was simply selected.
input_device() {
    command -v system_profiler >/dev/null 2>&1 || return 1
    system_profiler SPAudioDataType 2>/dev/null | awk '
        /^        [A-Za-z].*:$/ { dev = $0; sub(/^ +/, "", dev); sub(/:$/, "", dev) }
        /Default Input Device: Yes/ { print dev; exit }'
}

# Echoes a spoken-English sentence about whether the mic is working.
mic_health() {
    local lines heard=0 total=0 vol line n
    lines="$(tail -n 40 "$WAKE_LOG" 2>/dev/null)"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        total=$((total + 1))
        n="$(normalize "$line")"
        [[ -n "$n" ]] && heard=$((heard + 1))
    done <<< "$lines"

    vol="$(input_volume)"
    local dev volmsg=""
    dev="$(input_device)"
    [[ -n "$dev" ]] || dev="the input device"
    if [[ -n "$vol" ]]; then
        if [[ "$vol" -lt "$STT_WAKE_MIN_INPUT_VOLUME" ]]; then
            volmsg=" Input is $dev at volume $vol out of 100, too low to hear you. Raise it in Sound settings, or switch input to the MacBook microphone."
        else
            volmsg=" Input is $dev at volume $vol."
        fi
    fi

    if [[ "$total" -eq 0 ]]; then
        printf '%s' "I have not transcribed anything yet.$volmsg"
    elif [[ "$heard" -eq 0 ]]; then
        printf '%s' "I am hearing silence: none of the last $total segments contained speech.$volmsg"
    else
        printf '%s' "I can hear you: $heard of the last $total segments had speech.$volmsg"
    fi
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
CANCEL_STEM="$(stem8 "$STT_WAKE_CANCEL_WORD")"
REPEAT_TURN_STEM="$(stem8 "$STT_WAKE_REPEAT_TURN_WORD")"

# WHOLE WORD, not a prefix. matches_word matches by word-prefix so that
# "transcription" still fires "transcribe" — useful there, wrong for any command
# whose stem is also the start of an ordinary English word. Observed in the log:
# "adjudicated repeatedly" replayed a turn, and "playing." resumed playback.
# `send` already had a bespoke whole-word matcher for exactly this reason
# ("sending"/"sentence"); this is that rule, generalised.
matches_exact_word() {
    local line="$1" stem="$2" count=0 found=1 burst=1 w
    [[ -n "$stem" ]] || return 1
    for w in $line; do
        count=$((count + 1))
        if [[ "$w" == "$stem" || "$w" == "${stem}s" ]]; then
            found=0
        else
            burst=1$burst          # a non-matching word rules out a burst
        fi
    done
    [[ "$found" -eq 0 ]] || return 1
    # Repeat-to-force: a clean burst of nothing but the command word is always
    # the user, never narration. Same escape hatch matches_word gives.
    if [[ "$burst" == "1" && "$count" -ge 2 ]]; then
        return 0
    fi
    if player_speaking; then
        [[ "$count" -eq 1 ]] || return 1
    else
        # <=2 tolerates one filler ("uh repeat") but keeps the word from firing
        # out of the middle of continuous speech.
        [[ "$count" -le 2 ]] || return 1
    fi
    tts_recently_said "$stem" && return 1
    return 0
}
matches_repeat_turn() { matches_exact_word "$1" "$REPEAT_TURN_STEM"; }

# Why didn't that fire?
#
# Every rejection path in the dispatch chain is silent. Saying a command and
# having nothing happen therefore left NO trace anywhere — not in the lifecycle
# log, not on screen — which is precisely the failure that is impossible to
# debug and the one that actually wastes the day. Ten days of logs held 286
# lines and not one record of a command that was heard and dropped.
#
# So: if a line carried a command word and nothing fired, say why. Rate-limited
# per (stem, reason) because whisper's sliding window repeats the same utterance
# across several reads and would otherwise flood the log.
STT_WAKE_NEAR_MISS_QUIET="${STT_WAKE_NEAR_MISS_QUIET:-6}"
NEAR_MISS_KEYS=()
NEAR_MISS_AT=()
near_miss_quiet() {      # 0 = logged recently, stay quiet
    local key="$1" i
    for i in "${!NEAR_MISS_KEYS[@]}"; do
        if [[ "${NEAR_MISS_KEYS[$i]}" == "$key" ]]; then
            (( SECONDS - ${NEAR_MISS_AT[$i]} < STT_WAKE_NEAR_MISS_QUIET )) && return 0
            NEAR_MISS_AT[$i]=$SECONDS
            return 1
        fi
    done
    NEAR_MISS_KEYS+=("$key")
    NEAR_MISS_AT+=("$SECONDS")
    return 1
}
log_near_miss() {
    local norm="$1" raw="$2"
    [[ -n "$norm" ]] || return 0
    local count=0 w
    for w in $norm; do count=$((count + 1)); done
    (( count )) || return 0

    # stem:label:exact — "exact" commands must be the whole word, the rest match
    # by word-prefix. Listed in dispatch order.
    local spec stem label exact hit="" hitword="" whole=1
    for spec in \
        "$TRANSCRIBE_STEM:transcribe:0" "$REPEAT_TURN_STEM:repeat:1" \
        "$REPEAT_STEM:recap:0"         "$DIGEST_STEM:digest:0" \
        "$SEND_STEM:send:1"            "$DIAGNOSTIC_STEM:diagnostic:0" \
        "$WINDOW_STEM:window:0"        "$CANCEL_STEM:cancel:0" \
        "$PAUSE_STEM:pause:1"          "$PLAY_STEM:play:1" \
        "$FORWARD_STEM:forward:0"      "$REWIND_STEM:rewind:0" \
        "$CLEAR_STEM:clear:0"
    do
        stem="${spec%%:*}"; label="${spec#*:}"; exact="${label#*:}"; label="${label%%:*}"
        [[ -n "$stem" ]] || continue
        for w in $norm; do
            if [[ "$w" == "$stem"* ]]; then
                hit="$stem"; hitword="$w"
                [[ "$w" == "$stem" || "$w" == "${stem}s" ]] && whole=0
                break
            fi
        done
        [[ -n "$hit" ]] && break
    done
    [[ -n "$hit" ]] || return 0

    local reason
    if [[ "$echo_stem" == "$hit" ]]; then
        reason="echo latch for '$hit' still armed — clears on the next line without it, or after ${STT_WAKE_ECHO_LATCH_SECS}s"
    elif [[ "$exact" == "1" && "$whole" != "0" ]]; then
        reason="heard '$hitword', which only starts with '$hit' — '$label' must be the whole word"
    elif tts_recently_said "$hit"; then
        reason="suppressed as echo: the narration just said '$hit'"
    elif player_speaking && (( count > 1 )); then
        reason="narration is playing, so '$label' must be the only word — heard $count"
    elif (( count > 2 )); then
        reason="'$label' was inside a $count-word phrase — say it alone, or with at most one filler"
    elif [[ "$hit" == "$TRANSCRIBE_STEM" ]] && (( SECONDS - dict_ended < 3 )); then
        reason="within the 3s cooldown after dictation ended (its own audio tail is still in whisper's window)"
    else
        # Nothing above explains it, so say that rather than inventing a cause.
        # This line is the one to bring to a bug report.
        reason="UNEXPLAINED — matched no rule and no guard accounts for it"
    fi
    near_miss_quiet "$hit:$reason" && return 0
    log_lifecycle "no trigger ('$label' heard): $reason  [line: '$raw']"
}
SEND_STEM="$(stem8 "$STT_WAKE_SEND_WORD")"
# Whole-word matches only: "send", its plural "sends", and the common whisper
# mishearing "sent" (a clipped "send"). NEVER a prefix — "sending", "sender"
# and "sentence" must not submit (a bare send* false-fired on "just sending").
word_is_send() { [[ "$1" == "$SEND_STEM" || "$1" == "${SEND_STEM}s" || "$1" == "sent" ]]; }

# "send send send" — the frustrated repeat — must always land (BUG-027).
all_words_send() {
    local w count=0
    for w in $1; do
        count=$((count + 1))
        word_is_send "$w" || return 1
    done
    (( count >= 1 ))
}

# Send-specific matcher, same shape as matches_word but with the "sent"
# alias and the repeated-send escape hatch. The all-sends bypass is only
# honored while no TTS audio is in flight — narration ABOUT the send command
# must never press Enter (the a028ec9 cascade class).
matches_send() {
    local line="$1" count=0 found=1 w
    for w in $line; do
        count=$((count + 1))
        word_is_send "$w" && found=0
    done
    (( found == 0 )) || return 1
    # Repeat-to-force: "send send [send]" is unmistakably the user (narration
    # never emits only send-words) — honor it over live audio and the echo guard.
    if all_words_send "$line" && [[ "$count" -ge 2 ]]; then
        return 0
    fi
    local ok=1
    if player_speaking; then
        [[ "$count" -eq 1 ]] && ok=0
    else
        [[ "$count" -le 2 ]] && ok=0
    fi
    [[ "$ok" -eq 0 ]] || return 1
    # A lone/near-lone "send" the agent is currently narrating is mic echo.
    tts_recently_said "$SEND_STEM" && return 1
    return 0
}
WINDOW_STEM="$(stem8 "$STT_WAKE_WINDOW_WORD")"
PAUSE_STEM="$(stem8 "$STT_WAKE_PAUSE_WORD")"
PLAY_STEM="$(stem8 "$STT_WAKE_PLAY_WORD")"
FORWARD_STEM="$(stem8 "$STT_WAKE_FORWARD_WORD")"
REWIND_STEM="$(stem8 "$STT_WAKE_REWIND_WORD")"
DIGEST_STEM="$(stem8 "$STT_WAKE_DIGEST_WORD")"
DIAGNOSTIC_STEM="$(stem8 "$STT_WAKE_DIAGNOSTIC_WORD")"
CLEAR_STEM="$(stem8 "${STT_WAKE_CLEAR_WORD%% *}")"
CLEAR_NORM="$(normalize "$STT_WAKE_CLEAR_WORD")"

# Multi-word command ("text box"): contains-match on a short utterance.
matches_clear() {
    local line="$1" count
    [[ "$line" == *"$CLEAR_NORM"* ]] || return 1
    count="$(printf '%s' "$line" | wc -w | tr -d ' ')"
    [[ "$count" -le 4 ]]
}

# --- Command debounce ---------------------------------------------------------
# A command that seems not to have worked gets said again, and again. Every
# repeat used to fire: three "window"s meant three hand-offs, which is precisely
# the overlap that raced two narration loops into existence. So the SAME command
# within a short window is swallowed once it has already fired.
#
# Deliberately per-command, not global: saying "window" then immediately "recap"
# is a real sequence and must still work. And deliberately short — this is for
# the impatient re-say, not for stopping you using a command twice on purpose.
STT_WAKE_DEBOUNCE_SECS="${STT_WAKE_DEBOUNCE_SECS:-4}"
# ...but only where a repeat is EXPENSIVE. With the tone now firing the instant a
# command is recognised, the impatient re-say mostly stops happening, so debounce
# is back to what it should be: protection against duplicated work, not a general
# input filter.
#   recap/digest/diagnostic  full window — each repeat spawns a model call
#   window                   1s — cycling agents by saying it repeatedly is a
#                            REAL sequence; a 4s swallow would break it
#   cancel/forward/rewind/clear  none — cheap, and repeating them is meaningful
STT_WAKE_WINDOW_DEBOUNCE_SECS="${STT_WAKE_WINDOW_DEBOUNCE_SECS:-1}"
LAST_CMD_STEM=""
LAST_CMD_AT=-999

debounced() {
    local stem="$1" secs="$STT_WAKE_DEBOUNCE_SECS"
    case "$stem" in
        "$WINDOW_STEM") secs="$STT_WAKE_WINDOW_DEBOUNCE_SECS" ;;
        "$CANCEL_STEM"|"$FORWARD_STEM"|"$REWIND_STEM"|"$CLEAR_STEM") secs=0 ;;
    esac
    [[ "$secs" == "0" ]] && return 1
    if [[ "$stem" == "$LAST_CMD_STEM" ]] \
        && (( SECONDS - LAST_CMD_AT < secs )); then
        log_lifecycle "debounced '$stem' ($(( SECONDS - LAST_CMD_AT ))s since last)"
        return 0
    fi
    LAST_CMD_STEM="$stem"; LAST_CMD_AT=$SECONDS
    return 1
}

# The "window" hand-off speaks the target's name. Said rapidly, those pile up:
# each announcement is ~4s and a hand-off can be a second apart, so you hear
# three names talking over each other.
#
# The pid is tracked in a GLOBAL file rather than killed with `pkill -x say`,
# because the two obvious blunt fixes are both wrong: killing all `say` on
# teardown silenced the announcement for the pane you were moving TO (BUG-038),
# and doing nothing lets them overlap. Each hand-off is announced by a DIFFERENT
# listener process, so the file has to be global for the new one to find the old
# one's announcement. Exactly one label speaks at a time, and it is always the
# newest — which is the one that describes where you actually are.
ANNOUNCE_PID_FILE="$TTS_DIR/announce.pid"

announce() {
    local text="$1" prev
    [[ -n "$text" ]] || return 0
    command -v say >/dev/null 2>&1 || return 0
    prev="$(cat "$ANNOUNCE_PID_FILE" 2>/dev/null)"
    if [[ -n "$prev" ]] && kill -0 "$prev" 2>/dev/null; then
        kill "$prev" 2>/dev/null || true      # the older name is now stale
    fi
    say "$text" >/dev/null 2>&1 &
    echo "$!" > "$ANNOUNCE_PID_FILE" 2>/dev/null || true
}

# Fired the moment a command is RECOGNISED — before the handler does any work.
#
# It used to fire inside each handler, i.e. after the work, so the tone arrived
# anywhere from instantly (touch a channel file) to ~3s later ("send" waits for
# the input box to settle first). An acknowledgement that sometimes lands and
# sometimes does not is worse than none: you assume it did not hear you and say
# it again, which is what made repeats pile up in the first place.
#
# It also fires for a DEBOUNCED command. A swallowed command that made no sound
# is exactly the case that provokes another repeat — the tone has to say "heard
# you", separately from whether it acted.
ack() { chime "$STT_WAKE_ACK_SOUND" "$STT_WAKE_ACK_VOLUME"; }
buzz() { chime "$STT_WAKE_FAIL_SOUND" "$STT_WAKE_ACK_VOLUME"; }

# --- Mic self-echo guard -----------------------------------------------------
# The TTS plays through the speakers, the mic hears it, and a magic word IN THE
# NARRATION ("window", "send") would actuate the workspace. The new speak loop
# publishes what it's saying right now to $SPOOL/tts.speaking (content = the last
# couple chunks, refreshed while afplay runs). We use it two ways: to know TTS is
# live at all, and to drop a matched command word the narration is speaking.
TTS_SPEAKING_FILE="$SPOOL/tts.speaking"
TTS_ECHO_COOLDOWN="${STT_WAKE_ECHO_COOLDOWN:-2}"   # secs a spoken word stays "in the air"
                                                   # (short: the guard now reads only the
                                                   # CURRENT chunk, so it need only cover
                                                   # whisper's lag, not narration history)

# Seconds since the speaking file was last refreshed (huge if it doesn't exist).
tts_speaking_age() {
    local m now
    m="$(stat -f %m "$TTS_SPEAKING_FILE" 2>/dev/null)" || { echo 99999; return; }
    now="$(date +%s)"
    echo $(( now - m ))
}

# True while TTS audio is coming out of the speakers (mic-feedback risk): the OLD
# player has an afplay child, OR the NEW loop's speaking file is fresh.
player_speaking() {
    local pid
    pid="$(player_pid)"
    [[ -n "$pid" ]] && pgrep -P "$pid" -x afplay >/dev/null 2>&1 && return 0
    [[ "$(tts_speaking_age)" -le 1 ]]
}

# True if the narration is CURRENTLY (or just) speaking a word starting with the
# stem — i.e., a "match" is really the agent's own voice heard via the mic. The
# repeat-to-force burst (is_burst) deliberately bypasses this.
tts_recently_said() {
    local stem="$1" w
    [[ -n "$stem" && ${#stem} -ge 3 ]] || return 1
    [[ -f "$TTS_SPEAKING_FILE" ]] || return 1
    [[ "$(tts_speaking_age)" -le "$TTS_ECHO_COOLDOWN" ]] || return 1
    for w in $(cat "$TTS_SPEAKING_FILE" 2>/dev/null); do
        [[ "$w" == "$stem"* ]] && return 0
    done
    return 1
}

# A clean burst of the SAME command word ("window window", "send send send") is
# unmistakably the user — narration never repeats a lone command word — so it
# always fires, even over live TTS and past the echo guard. This is the reliable
# way to force a command while the agent is talking.
is_burst() {
    local line="$1" stem="$2" count=0 w
    [[ -n "$stem" ]] || return 1
    for w in $line; do
        count=$((count + 1))
        [[ "$w" == "$stem"* ]] || return 1   # any non-stem word => not a clean burst
    done
    [[ "$count" -ge 2 ]]
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
    # Repeat-to-force: a clean burst of the command word is always the user.
    is_burst "$line" "$stem" && return 0
    local count=0 found=1 w last=""
    for w in $line; do
        count=$((count + 1))
        last="$w"
        [[ "$w" == "$stem"* ]] && found=0
    done
    local ok=1
    if [[ "$mode" == "end" ]]; then
        [[ "$last" == "$stem"* && "$count" -le 6 ]] && ok=0
    elif player_speaking; then
        [[ "$found" -eq 0 && "$count" -eq 1 ]] && ok=0
    else
        # Commands are spoken as lone words; <=2 tolerates a filler ("uh
        # send") but keeps fragments of continuous speech from triggering.
        [[ "$found" -eq 0 && "$count" -le 2 ]] && ok=0
    fi
    [[ "$ok" -eq 0 ]] || return 1
    # Would match — but drop it if it's the agent's own narration via the mic.
    tts_recently_said "$stem" && return 1
    return 0
}

: > "$WAKE_LOG"
whisper-stream -m "$MODEL_PATH" -t 4 --step "$STT_WAKE_STEP_MS" --length 6000 \
    -f "$WAKE_LOG" >/dev/null 2>> "$SPOOL/error.log" &
echo "$!" > "$STREAM_PID_FILE"
echo "listening" > "$STATE_FILE"
log_lifecycle "listening for '$STT_WAKE_TRANSCRIBE_WORD' / '$STT_WAKE_REPEAT_WORD' / '$STT_WAKE_SEND_WORD'"

# Say something the moment the mic is too quiet to work, rather than waiting for
# someone to notice that no command has landed for twenty minutes and think to
# ask for a diagnostic. Checked at start-up only: input volume is a system
# setting other apps change (a call, a meeting), so it is right at exactly the
# moment the mode is turned on and can drift afterwards — the `diagnostic`
# command covers the drift case.
#
# Deliberately warns rather than raising the volume itself. Silently rewriting a
# system audio setting is the kind of thing that surprises someone mid-meeting,
# and being told is enough: the fix is one slider.
# Raise it rather than only complaining. Five separate sessions have now ended
# at a too-quiet input, and the warning added earlier did its job — it named the
# cause immediately instead of costing twenty minutes — but the remaining step
# was still a human walking to Sound settings every time.
#
# The earlier argument against touching a system setting was that it could
# surprise someone mid-meeting. That does not apply HERE: this runs only when
# speak mode is deliberately switched on, and voice mode with an inaudible
# microphone is not a state anyone wants. It raises only to a floor, never
# lowers, says out loud what it changed, and is one config flag to disable.
#
# Observed levels when found broken: 27, 27, 29 — and once raised it holds, so
# whatever sets it is an event (device switch, a call, sleep/wake) rather than a
# process continuously fighting us.
STT_WAKE_AUTO_RAISE_INPUT="${STT_WAKE_AUTO_RAISE_INPUT:-1}"
STT_WAKE_TARGET_INPUT_VOLUME="${STT_WAKE_TARGET_INPUT_VOLUME:-75}"

_vol="$(input_volume)"
if [[ -n "$_vol" && "$_vol" -lt "$STT_WAKE_MIN_INPUT_VOLUME" ]]; then
    _dev="$(input_device)"; [[ -n "$_dev" ]] || _dev="the input device"
    if [[ "$STT_WAKE_AUTO_RAISE_INPUT" == "1" ]] && command -v osascript >/dev/null 2>&1; then
        osascript -e "set volume input volume $STT_WAKE_TARGET_INPUT_VOLUME" 2>/dev/null
        _new="$(input_volume)"
        if [[ -n "$_new" && "$_new" -ge "$STT_WAKE_MIN_INPUT_VOLUME" ]]; then
            log_lifecycle "raised $_dev input volume $_vol -> $_new (was below $STT_WAKE_MIN_INPUT_VOLUME)"
            tmux display-message -t "$PANE_ID" \
                "🎤 Raised $_dev input volume $_vol → $_new" 2>/dev/null || true
            command -v say >/dev/null 2>&1 && \
                ( say "Microphone was too quiet. Raised $_dev input to $_new." >/dev/null 2>&1 & )
        else
            log_lifecycle "WARNING: could not raise $_dev input volume (still ${_new:-$_vol})"
            tmux display-message -t "$PANE_ID" \
                "🎤 $_dev input volume ${_new:-$_vol} is too low and could not be raised" 2>/dev/null || true
            command -v say >/dev/null 2>&1 && \
                ( say "Warning. $_dev input is too quiet and I could not raise it." >/dev/null 2>&1 & )
        fi
    else
        log_lifecycle "WARNING: $_dev input volume $_vol < $STT_WAKE_MIN_INPUT_VOLUME — voice commands will not be heard"
        tmux display-message -t "$PANE_ID" \
            "🎤 $_dev input volume $_vol is too low — voice commands will not be heard" 2>/dev/null || true
        command -v say >/dev/null 2>&1 && \
            ( say "Warning. $_dev input volume is $_vol, too low to hear commands." >/dev/null 2>&1 & )
    fi
fi

state="listening"
dict_started=0
dict_ended=0
# The word that just triggered lingers in whisper's ~6s sliding window and
# re-appears in the next segment(s). Until a line WITHOUT that stem arrives,
# the same command must not fire again — otherwise saying "transcribe" starts
# dictation and its own echo immediately ends it.
#
# It also expires on TIME. Blank lines deliberately do not clear it (a spoken
# word keeps reappearing in whisper's window for a few seconds), but silence is
# the normal state, so without an expiry the latch wedged armed and the command
# could never fire again — four consecutive "transcribe" utterances were
# observed doing nothing, hours after the last successful trigger. Past
# whisper's --length 6000 window the latch has no job left.
echo_stem=""
STT_WAKE_ECHO_LATCH_SECS="${STT_WAKE_ECHO_LATCH_SECS:-8}"
echo_stem_at=0
# Was the PREVIOUS line a lone "send"? A real "send" lingers in whisper's window
# so it lands on >=2 consecutive reads; an echo of narrated "send" is embedded in
# a sentence (count>1) and never counts as lone. So "lone send twice in a row"
# forces the command through even when the echo guard would block it (the agent
# narrating a messaging feature says "send" constantly, false-blocking the real
# command). See SEND_FORCE below.
send_lone_prev=0

# True when the line is exactly one word and that word is a send-word.
is_lone_send() {
    local c=0 w
    for w in $1; do c=$((c + 1)); done
    [[ "$c" -eq 1 ]] && word_is_send "$1"
}

line_has_stem() {
    local line="$1" stem="$2" w
    [[ -n "$stem" ]] || return 1
    for w in $line; do
        [[ "$w" == "$stem"* ]] && return 0
    done
    return 1
}

# Does the line contain any send-word (send/sends/sent)? Used by the
# alias-aware echo guard so the send trigger's own echo — heard as "sent" —
# keeps the guard armed instead of slipping past a bare "send" stem check.
line_has_send() {
    local line="$1" w
    for w in $line; do
        word_is_send "$w" && return 0
    done
    return 1
}

# Alias-aware echo test. transcribe and send are ALSO recognized via their
# whisper-mishearing aliases ("subscribe", "sent"), so the guard must keep
# suppressing until the line contains NEITHER the stem NOR any alias —
# otherwise the trigger word's own echo, heard as the alias, clears the guard
# and immediately re-fires the command (transcribe would end its own dictation;
# send would press Enter a second time). Other commands have no alias and fall
# through to the plain stem check.
line_has_echo() {
    local line="$1" stem="$2"
    if [[ "$stem" == "$TRANSCRIBE_STEM" ]]; then
        line_has_stem "$line" "$TRANSCRIBE_STEM" \
            || line_has_stem "$line" "$TRANSCRIBE_ALT_STEM"
    elif [[ "$stem" == "$SEND_STEM" ]]; then
        line_has_send "$line"
    else
        line_has_stem "$line" "$stem"
    fi
}

# Strip the toggle words from a transcript's edges. Shared by the normal
# end-of-take path and by roll_dictation, which passes an empty stop word
# because a mid-take segment has no stop phrase yet.
strip_edges() {
    python3 - "$1" "$2" "$3" <<'PY'
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
    # Strip a RUN of trailing command words, not just one. Saying "send" twice
    # when the first one seemed not to work is the normal human response, and
    # the repeats land in the recording tail: "...again? Send. Send. Send."
    # One substitution left the earlier ones inside the message.
    pat = r"(?i)\s+" + tail + r"[\s.,!?]*$"
    while True:
        stripped = re.sub(pat, "", text)
        if stripped == text:
            break
        text = stripped
print(text.strip())
PY
}

# Transcribe one dictation take. Shared by the normal end-of-take path and by
# roll_dictation, which flushes a segment mid-take. Includes the silence guard:
# whisper invents words out of near-silence, so a quiet file transcribes to
# nothing rather than to a hallucination.
wav_speech_text() {
    local wav="$1" size rms
    size="$(stat -f%z "$wav" 2>/dev/null || stat -c%s "$wav" 2>/dev/null || echo 0)"
    (( size > 1000 )) || return 0
    if command -v sox >/dev/null 2>&1; then
        rms="$(sox "$wav" -n stat 2>&1 | awk '/RMS[[:space:]]+amplitude/ {print $NF; exit}')"
        if [[ -n "$rms" ]] && awk -v r="$rms" 'BEGIN { exit !(r+0 < 0.003) }'; then
            return 0
        fi
    fi
    "$SCRIPT_DIR/transcribe.sh" "$wav" 2>/dev/null || true
}

# Close the current segment and immediately open the next one, without leaving
# dictating state.
#
# The cap used to call end_dictation: the take simply stopped, and everything
# said afterwards went nowhere. "When I speak for a long time the transcription
# just turns off randomly... I don't realize it's turned off and I keep talking."
# Nothing is dropped now — the text so far lands in the input box and recording
# continues, so a long take is a sequence of segments rather than a cliff.
#
# Order matters: the new recorder starts BEFORE the old segment is transcribed.
# whisper-cli on a two-minute take is seconds of work, and anything spoken
# during it would be exactly the speech this is meant to stop losing.
roll_dictation() {
    local old_pid part text
    old_pid="$(cat "$REC_PID_FILE" 2>/dev/null)"
    part="$DICT_WAV.part"
    rm -f "$part"
    [[ -n "$old_pid" ]] && kill_recorder "$old_pid"
    mv -f "$DICT_WAV" "$part" 2>/dev/null
    rec -b 16 -c 1 -r 16000 "$DICT_WAV" 2>"$SPOOL/dictation-rec.log" &
    echo "$!" > "$REC_PID_FILE"
    dict_started=$SECONDS
    log_lifecycle "dictation rolled at ${STT_WAKE_MAX_DICTATION}s — segment flushed, still recording"
    text="$(wav_speech_text "$part")"
    rm -f "$part"
    [[ -n "$text" ]] || return 0
    # Only the head word can appear in a mid-take segment; there is no stop word
    # yet, so pass an empty one.
    text="$(strip_edges "$text" "$STT_WAKE_TRANSCRIBE_WORD" "")"
    [[ -n "$text" ]] || return 0
    text="${text//$'\r'/ }"
    text="${text//$'\n'/ }"
    mode_active || return 0
    # Trailing space so the next segment does not run into this one.
    tmux send-keys -t "$PANE_ID" -l "$text " 2>/dev/null || return 0
    INJECTED=1
    INJECTED_CHARS=$(( INJECTED_CHARS + ${#text} + 1 ))
    chime "$STT_WAKE_STOP_SOUND"
    log_lifecycle "dictation segment injected: ${#text} chars (take continues)"
}

begin_dictation() {
    state="dictating"
    INJECTED_CHARS=0          # counts the whole take, across any rolled segments
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
    text="$(wav_speech_text "$DICT_WAV")"
    rm -f "$DICT_WAV"

    if [[ -n "$text" ]]; then
        # The stop phrase lands in the recording tail (and the start phrase
        # occasionally in the head) — strip them from the edges.
        text="$(strip_edges "$text" "$STT_WAKE_TRANSCRIBE_WORD" "$stop_word")"
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

    # Collapse any stray newlines from the transcript to spaces before
    # injecting — a literal newline sent via send-keys -l can fragment the
    # message inside Claude Code's input box (BUG-030).
    text="${text//$'\r'/ }"
    text="${text//$'\n'/ }"
    # transcribe.sh runs synchronously and a long take (up to
    # STT_WAKE_MAX_DICTATION s) can outlast the mode: if speak mode was toggled
    # off (or moved to another pane) while it ran, don't inject stale dictation
    # into a pane that is no longer bound.
    if ! mode_active; then
        log_lifecycle "dictation dropped: mode no longer active on this pane"
        return 0
    fi
    INJECTED_CHARS=$(( INJECTED_CHARS + ${#text} ))
    tmux send-keys -t "$PANE_ID" -l "$text" 2>/dev/null && INJECTED=1
    if [[ "$INJECTED" == "1" ]]; then chime "$STT_WAKE_STOP_SOUND"; else buzz; fi
    local preview="$text"
    [[ ${#preview} -gt 60 ]] && preview="${preview:0:60}..."
    tmux display-message -t "$PANE_ID" "Transcribed: $preview" 2>/dev/null || true
    log_lifecycle "dictation injected: ${#text} chars"
}

# "repeat that": run the recap routine again (the speak-mode equivalent of
# Ctrl+b p) — scan back, summarize, speak, then resume streaming. Plays
# through the mode's own audio queue, so no playback-slot conflict.
do_repeat() {
    # New tail->rewrite->speak loop: recap is handled by speak_loop.py's own
    # recapper (touch its repeat file), NOT the old stream-framing worker —
    # whose "preparing" beeper is the sticks sound and whose audio never reaches
    # the new loop's player (BUG-032).
    if [[ -n "${SPEAKLOOP_PAUSE_FILE:-}" ]]; then
        local rf="${SPEAKLOOP_REPEAT_FILE:-${SPEAKLOOP_PAUSE_FILE%.pause}.repeat}"
        if [[ "$PAUSED" == "1" ]]; then          # recap overrides a standing pause
            PAUSED=0; rm -f "$SPOOL/paused"; resume_playback
            log_lifecycle "repeat: implicit play (was paused)"
        fi
        : > "$rf"
        log_lifecycle "repeat: recap requested (new loop) -> $rf"
        tmux display-message -t "$PANE_ID" "🔁 Recapping…" 2>/dev/null || true
        return 0
    fi
    local fpid
    fpid="$(framing_pid)"
    if [[ -n "$fpid" ]] && kill -0 "$fpid" 2>/dev/null; then
        log_lifecycle "repeat ignored: recap already running"
        buzz
        return 0
    fi
    # Asking to hear the recap is an unambiguous request for audio — it
    # overrides a standing pause. Without this, the recap is enqueued into a
    # SIGSTOPped player and plays nothing (BUG-026).
    if [[ "$PAUSED" == "1" ]]; then
        PAUSED=0
        rm -f "$SPOOL/paused"
        resume_playback
        log_lifecycle "repeat: implicit play (was paused)"
    fi
    log_lifecycle "repeat: recap requested"
    touch "$SPOOL/framing.lock"
    TTS_STREAM_RECAP_CHARS="${TTS_STREAM_DIGEST_CHARS:-900}" \
        nohup "$SCRIPT_DIR/../tts/stream-framing.sh" "$PANE_ID" "$SPOOL" >/dev/null 2>&1 &
    echo "$!" > "$SPOOL/framing.pid"
    tmux display-message -t "$PANE_ID" "🔁 Recapping…" 2>/dev/null || true
}

# "send": press Enter in the bound pane — submits whatever the earlier
# dictation left in the input box.
do_send() {
    # Wait for any injected dictation to fully land before submitting. Claude
    # Code ingests a big send-keys paste asynchronously, so an early Enter
    # fires before the text lands and submits nothing, stranding it in the box
    # (BUG-030). This is the common "transcribe to inject, then say 'send'"
    # flow — not just the combined send-end path — so the wait lives here.
    # ~1s per 200 chars on top of the base, capped at 12s.
    local _need=$(( 2500 + (INJECTED_CHARS * 5) ))
    (( _need > 12000 )) && _need=12000
    # Do not accept "stable" before the paste has plausibly finished arriving.
    local _floor=$(( 300 + (INJECTED_CHARS * 2) ))
    (( _floor > 4000 )) && _floor=4000
    local _pending="$INJECTED_CHARS"
    wait_input_ready "$_need" "$_floor" "$_pending" \
        || log_lifecycle "send: input never settled after ${_need}ms; submitting best-effort"
    # What the box holds now is what we are about to submit — the baseline the
    # post-Enter check compares against.
    local _before
    _before="$(capture_input_region)"
    _before="${_before#❯}"
    _before="${_before# }"
    # Nothing in the box and nothing injected: there is no message to send. Say
    # so instead of pressing Enter and reporting success — which is what the
    # previous version did, because an empty `_before` makes the needle empty and
    # the first poll then sees "text is gone" on a box that was never filled.
    # This is the common second "send" after one that already worked.
    if [[ -z "$_before" && "$_pending" -eq 0 ]]; then
        buzz
        log_lifecycle "send: nothing to send — the input box is empty"
        tmux display-message -t "$PANE_ID" "⚠️ Nothing to send" 2>/dev/null || true
        return 0
    fi
    if ! tmux send-keys -t "$PANE_ID" Enter 2>/dev/null; then
        log_lifecycle "send FAILED: send-keys error"
        buzz
        INJECTED_CHARS=0
        return 0
    fi
    # "Did it submit?" is whether OUR TEXT LEFT THE BOX — not whether the box is
    # empty. Those are different questions, and answering the wrong one buzzed on
    # messages that had actually been sent: one was in the agent's transcript at
    # the same second this logged "not submitted". A false failure is worse than
    # no signal, because the natural response is to say "send" again — and those
    # repeats get transcribed INTO the next message ("Send. Send. Send.").
    #
    # A single 0.3s sample was also too eager: the box clears on the next render,
    # not instantly. Poll instead, and stop as soon as the text is gone.
    local _needle="${_before:0:24}"
    local _after="" _gone=1 _el=0 _pstart
    _pstart="$(now_ms)"
    while :; do
        _after="$(capture_input_region)"
        if [[ -z "$_after" ]] || { [[ -n "$_needle" ]] && [[ "$_after" != *"$_needle"* ]]; }; then
            _gone=0
            break
        fi
        _el=$(( $(now_ms) - _pstart ))
        (( _el >= 2500 )) && break
        (( _el < 400 )) && sleep 0.1
    done
    if [[ -z "$_before" ]]; then
        # Injected text that never rendered (BUG-030's phantom paste). Enter was
        # the right move, but the screen cannot confirm it either way, so say
        # that rather than claiming a clean send.
        chime "$STT_WAKE_SEND_SOUND"
        log_lifecycle "send: injected $_pending chars but the box rendered empty; Enter sent, UNCONFIRMED"
        tmux display-message -t "$PANE_ID" "📨 Sent (unconfirmed)" 2>/dev/null || true
    elif [[ "$_gone" -eq 0 ]]; then
        chime "$STT_WAKE_SEND_SOUND"
        log_lifecycle "send: submitted (text left the box after ${_el}ms)"
        tmux display-message -t "$PANE_ID" "📨 Sent" 2>/dev/null || true
    else
        buzz
        log_lifecycle "send: box still holds the same text after ${_el}ms — not submitted"
        tmux display-message -t "$PANE_ID" "⚠️ Send did not submit" 2>/dev/null || true
    fi
    # The size belongs to THIS dictation. Leaving it set meant the next bare
    # "send" inherited the last dictation's budget: after a 704-char take, a
    # plain "send" waited 6s against an empty box for no reason.
    INJECTED_CHARS=0
}

# Read the current contents of PANE_ID's Claude Code input box: the text
# between the bottom-most pair of horizontal rules, with the "❯" prompt and its
# non-breaking-space padding stripped. Returns an empty string when the box
# holds only the bare prompt. Used to confirm an injected dictation has fully
# landed before Enter is pressed.
capture_input_region() {
    # The input box is bracketed by two PLAIN horizontal rules. Box-drawing
    # borders are not rules: a rendered table's `┌───┬───┐` / `├───┼───┤` lines
    # all contain "──────────" too, so counting them meant that whenever a table
    # (or any bordered block) rendered BELOW the input box, "the last two rules"
    # bracketed table rows instead of the box. Junction characters are the
    # discriminator; the box's own rules never contain them.
    #
    # All of the trimming happens inside the single awk. This used to be a
    # six-process pipeline (awk | sed | tr | sed), and the function is called in
    # a polling loop, so that overhead was paid dozens of times per send.
    tmux capture-pane -p -t "$PANE_ID" 2>/dev/null | awk '
        {
            _t = $0
            gsub(/─/, "", _t)
            gsub(/[ \t]/, "", _t)
            if (_t == "" && index($0, "──────────")) rules[++n] = NR
            line[NR] = $0
        }
        END {
            if (n < 2) exit
            out = ""
            for (i = rules[n-1] + 1; i < rules[n]; i++) {
                s = line[i]
                sub(/^❯/, "", s)
                gsub(/ /, " ", s)           # NBSP padding (literal)
                out = out " " s
            }
            gsub(/[ \t]+/, " ", out)
            sub(/^ +/, "", out)
            sub(/ +$/, "", out)
            printf "%s", out
        }'
}

# Milliseconds on the wall clock. The polling loops below used to count 100ms
# per iteration on the assumption that the sleep dominated. It does not: one
# capture_input_region costs ~525ms here, because every tmux command is a
# round-trip to a single-threaded server that is busy with the other panes. So
# every budget ran about 5x longer than it said — a "2.5s" wait really took 13
# seconds, and a long dictation's 6s wait took over 30. That is most of what
# "voice commands are broken" actually felt like.
now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [[ -n "$t" ]]; then
        t="${t/,/.}"
        printf '%s' "$(( ${t%%.*} * 1000 + 10#${t#*.} / 1000 ))"
    else
        printf '%s' "$(( $(date +%s) * 1000 ))"
    fi
}

# Block until the injected dictation is visible AND stable in the input box
# (done streaming) before the caller presses Enter. A fixed sleep raced large
# pastes: Claude Code ingests a big send-keys blob asynchronously, so the Enter
# fired before the text landed and submitted nothing, stranding the message in
# the box (BUG-030). Polls the input region and returns once it is non-empty
# and unchanged across two reads; capped so a genuinely busy/streaming pane
# still submits best-effort rather than hanging.
wait_input_ready() {
    # Scale with the size of what was injected. Claude Code ingests a big
    # send-keys paste asynchronously, and a flat 2.5s cap timed out on long
    # dictations — Enter then fired before the text had landed and nothing
    # submitted. Both of today's failures were long (933 and 818 chars) while
    # the 1022-char one that happened to settle in time succeeded, which is the
    # signature of a cap that is simply too tight rather than a broken paste.
    # "Unchanged across two reads" is not sufficient on its own. capture-pane
    # reads the RENDERED box, and while a large paste is still arriving two
    # consecutive reads can return the SAME partial text — which looks stable and
    # is not. Observed: 329 chars injected, Enter fired 1s later against a
    # budget of 4.1s, and the box still held text afterwards. Across a day that
    # was 42 failed submits against 37 successful ones.
    #
    # So stability must also clear a FLOOR that scales with what was sent. The
    # floor is a minimum, `max` is the ceiling, and the length check is
    # deliberately not used as the signal: the rendered box wraps and truncates,
    # so its character count is not comparable to what was injected.
    local prev="" cur stable=0 waited=0 _start
    local max="${1:-2500}"
    local floor="${2:-0}"
    # How many characters we injected this cycle. With nothing pending there is
    # nothing to wait FOR: an empty box was treated as "not ready", so a bare
    # "send" sat here for the whole budget — up to 12s of apparent deadness —
    # and then logged "input never settled", which reads like a fault and is
    # not one. When we DID inject, an empty box still means the paste has not
    # rendered yet, so that case keeps waiting exactly as before.
    local expect="${3:-0}"
    (( floor > max )) && floor=$max
    _start="$(now_ms)"
    while :; do
        cur="$(capture_input_region)"
        waited=$(( $(now_ms) - _start ))
        if [[ -z "$cur" && "$expect" -eq 0 ]]; then
            return 0
        fi
        if [[ -n "$cur" ]]; then
            if [[ "$cur" == "$prev" ]]; then
                stable=$((stable + 1))
                (( stable >= 2 && waited >= floor )) && return 0
            else
                stable=0
            fi
        fi
        prev="$cur"
        (( waited >= max )) && return 1
        # The capture itself is the sampling interval; only pad it when it came
        # back unusually fast.
        (( waited < 400 )) && sleep 0.1
    done
}

# "diagnostic": speak a pipeline health report through a DIRECT local path
# (macOS `say`), deliberately bypassing the stream queue — when the pipeline
# is the thing that's broken, the report must not depend on it. Checks
# workers, queue depths, pause/suspend state, and edge-tts reachability (the
# usual no-network casualty).
do_diagnostic() {
    # New tail->rewrite->speak loop: the old worker/queue model doesn't apply
    # (it would report "all dead"). Report the honest new-loop state instead.
    if [[ -n "${SPEAKLOOP_PAUSE_FILE:-}" ]]; then
        local report="" sp
        sp="$(cat "${SPEAKLOOP_PAUSE_FILE%.pause}.pid" 2>/dev/null)"
        if [[ -n "$sp" ]] && kill -0 "$sp" 2>/dev/null; then
            report="Narration loop alive."
        else
            report="Narration loop is down."
        fi
        if pgrep -f "whisper-stream .*${PANE_ID#%}\.stream" >/dev/null 2>&1; then
            report="$report Voice listener alive."
        else
            report="$report Voice listener is down."
        fi
        report="$report $(mic_health)"
        [[ "$PAUSED" == "1" ]] && report="$report Playback paused, say ${STT_WAKE_PLAY_WORD} to resume."
        if curl -s -m 3 -o /dev/null "https://speech.platform.bing.com" 2>/dev/null; then
            report="$report Speech service reachable."
        else
            report="$report Speech service unreachable, check network."
        fi
        log_lifecycle "diagnostic (new loop): $report"
        command -v say >/dev/null 2>&1 && ( say "Diagnostic. $report" >/dev/null 2>&1 & )
        tmux display-message -t "$PANE_ID" "🩺 $report" 2>/dev/null || true
        return 0
    fi
    local report="" dead="" f pid
    for f in watcher synth player rewrite wake; do
        pid="$(cat "$SPOOL/$f.pid" 2>/dev/null)"
        { [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; } || dead="$dead $f"
    done
    if [[ -n "$dead" ]]; then
        report="Dead workers:${dead}."
    else
        report="All workers alive."
    fi
    if [[ "$PAUSED" == "1" ]]; then
        report="$report Playback is paused, say ${STT_WAKE_PLAY_WORD} to resume."
    else
        pid="$(player_pid)"
        if [[ -n "$pid" ]] && ps -o stat= -p "$pid" 2>/dev/null | grep -q T; then
            report="$report Player is suspended unexpectedly."
        fi
    fi
    local nraw nchunk naudio
    nraw="$(ls "$SPOOL/raw" 2>/dev/null | grep -c '\.txt$')"
    nchunk="$(ls "$SPOOL/chunks" 2>/dev/null | grep -c '\.txt$')"
    naudio="$(ls "$SPOOL/audio" 2>/dev/null | grep -c '\.mp3$')"
    report="$report Queues: $nraw raw, $nchunk text, $naudio audio."
    if curl -s -m 3 -o /dev/null "https://speech.platform.bing.com" 2>/dev/null; then
        report="$report Speech service reachable."
    else
        report="$report Speech service unreachable, check network."
    fi
    command -v codex >/dev/null 2>&1 || report="$report Codex is missing."
    log_lifecycle "diagnostic: $report"
    if command -v say >/dev/null 2>&1; then
        ( say "Diagnostic. $report" >/dev/null 2>&1 & )
    fi
    tmux display-message -t "$PANE_ID" "🩺 $report" 2>/dev/null || true
}

# "window": move the speak-mode binding (and the purple) onward — next window
# in the bound pane's session, or next pane when there's only one window
# (command-center layout). Re-binding goes through toggle-stream's move path,
# which also replaces this listener; the recap frames the new pane.
do_window() {
    # New tail->rewrite->speak loop: cycle narration through the panes of the
    # bound pane's OWN window (the command-center grid) — NEVER leaving the
    # window, so the command view survives. Each agent is a pane; select-pane
    # focuses the target so its purple shows in the grid. Single-owner handoff.
    if [[ -n "${SPEAKLOOP_PAUSE_FILE:-}" ]]; then
        local ncur target=""
        ncur="$(tmux display-message -pt "$PANE_ID" '#{window_id}' 2>/dev/null)"
        # Cycle in PANE-ID order, not the order tmux lists them in.
        #
        # `list-panes` returns panes by pane_index — a POSITIONAL list — and the
        # command-center's focus hook (tmux-cc-focus.sh) promotes whatever you
        # select into the main slot with `swap-pane`, which exchanges exactly
        # those positions. So walking the listed order ping-pongs: you move to
        # index 1, promote swaps it to index 0 and puts the pane you left at
        # index 1, and the next "window" walks straight back to it. On a
        # six-agent grid that reached two panes and stranded the other four.
        #
        # Pane ids are assigned at creation and never move, so sorting by the
        # numeric part gives a stable round-robin that swap-pane cannot disturb.
        # It is also creation order, which is a more meaningful cycle than a
        # layout order the promote hook is actively rewriting under us.
        local panes=() pp pj=0 pidx=-1
        while IFS= read -r pp; do
            panes+=("$pp"); [[ "$pp" == "$PANE_ID" ]] && pidx=$pj; pj=$((pj + 1))
        done < <(tmux list-panes -t "$ncur" -F '#{pane_id}' 2>/dev/null \
                 | sort -t% -k2 -n)
        if (( ${#panes[@]} > 1 && pidx >= 0 )); then
            target="${panes[$(( (pidx + 1) % ${#panes[@]} ))]}"
        fi
        if [[ -z "$target" || "$target" == "$PANE_ID" ]]; then
            log_lifecycle "window: only one pane in this window, nothing to cycle"
            buzz
            return 0
        fi
        log_lifecycle "window (new loop): move narration $PANE_ID -> $target (same window)"
        # Instant spoken cue of the target agent (env name, else window name);
        # the recap-on-start follows with the fuller framing.
        local tpath tlabel=""
        tpath="$(tmux display-message -pt "$target" '#{pane_current_path}' 2>/dev/null)"
        case "$tpath" in
            */envs/*) tlabel="${tpath#*/envs/}"; tlabel="${tlabel%%/*}" ;;
            *)        tlabel="$(tmux display-message -pt "$target" '#{window_name}' 2>/dev/null)" ;;
        esac
        announce "$tlabel"
        # Focus the target pane but STAY in this window (no select-window — that
        # would leave the command grid).
        tmux select-pane -t "$target" 2>/dev/null || true
        # Launch the target stack fully detached (subshell backgrounds it, then
        # exits, reparenting it to init) so the single-owner teardown of OUR
        # stack can't kill the launcher mid-handoff.
        ( SPEAKLOOP_RECAP_ON_START=1 \
            nohup bash "$SCRIPT_DIR/../../prototype/toggle-speak.sh" "$target" >/dev/null 2>&1 & )
        return 0
    fi
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
        done < <(tmux list-panes -t "$sess:" -F '#{pane_id}' 2>/dev/null \
                 | sort -t% -k2 -n)   # pane-id order: see the new-loop branch
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
    # Announce where we landed — env name if the pane lives in an env,
    # else the tmux window name.
    local tpath tlabel
    tpath="$(tmux display-message -pt "$target" '#{pane_current_path}' 2>/dev/null)"
    case "$tpath" in
        */envs/*) tlabel="${tpath#*/envs/}"; tlabel="${tlabel%%/*}" ;;
        *)        tlabel="$(tmux display-message -pt "$target" '#{window_name}' 2>/dev/null)" ;;
    esac
    announce "$tlabel"
    nohup "$SCRIPT_DIR/../tts/toggle-stream.sh" "$target" >/dev/null 2>&1 &
}

PAUSED=0
INJECTED=0
INJECTED_CHARS=0

# "send" while dictating: the closing word often lands in the SAME whisper
# segment as the last dictated words ("...make it purple. Send.") — the old
# <=2-word rule missed those, and missed "send send send" bursts entirely
# (six sends in one segment can never be <=2 words). Accept:
#   (a) a short utterance (<=2 words) ending send-ish,
#   (b) a segment that is nothing but send-words, any count,
#   (c) the RAW segment ending with "Send."/"Sent." as its OWN sentence
#       (whisper punctuates the command apart from the prose; plain prose
#       that happens to end "...was sent." lacks the preceding boundary),
#       capped at 12 words so long prose merely mentioning it stays content.
# Words that make a trailing "send" a VERB rather than the command: "...want you
# to send", "...I will send", "...can you send". Those must not submit.
# Everything else ending on "send" is the command.
SEND_VERB_BEFORE=" to will would can could should shall must may might please cant wont dont doesnt didnt "

ends_with_send() {
    local norm="$1" raw="$2" count=0 last="" prev="" w
    [[ -n "$SEND_STEM" ]] || return 1
    for w in $norm; do
        count=$((count + 1))
        prev="$last"
        last="$w"
    done
    if word_is_send "$last" && (( count <= 2 )); then return 0; fi
    all_words_send "$norm" && return 0
    # A line that ENDS on the send word closes the take. This used to also
    # require punctuation immediately before it —
    # `[.!?,;:][[:space:]]*[Ss][Ee][Nn][DdTt]` — on the theory that a real
    # command trails a finished sentence. But whisper's punctuation is
    # arbitrary, so identical intent worked or didn't depending on whether it
    # happened to emit a comma: "can you work on those things? Send." fired
    # while "can you work on those things send" did not, and "lets do that
    # send." did not either. That is the whole of "I have to say send ten
    # times" — each repeat was a coin flip on punctuation.
    #
    # So: last word is the send word, within a generous cap (whisper's 6s window
    # runs long during continuous speech), minus the verb readings above.
    word_is_send "$last" || return 1
    (( count <= STT_WAKE_SEND_END_MAX_WORDS )) || return 1
    [[ "$SEND_VERB_BEFORE" == *" $prev "* ]] && return 1
    return 0
}

kill_inflight_afplay() {
    local pid child
    pid="$(player_pid)"
    [[ -n "$pid" ]] || return 0
    for child in $(pgrep -P "$pid" -x afplay 2>/dev/null); do
        kill -9 "$child" 2>/dev/null || true
    done
}

# "cancel": clear the WHOLE buffer and go quiet, but keep listening. Said when
# the narration has fallen behind and stopped being worth hearing — everything
# ordered so far is dropped, and new output still narrates. A clean slate, the
# same effect changing windows has, not an off switch. ("forward" is the
# narrower one: drop what is synthesised and waiting, keep work in flight.)
# Clears a standing pause so future narration is actually audible.
do_cancel() {
    if [[ -z "${SPEAKLOOP_PAUSE_FILE:-}" ]]; then
        buzz
        log_lifecycle "cancel: not supported by the old stream mode"
        return 0
    fi
    : > "${SPEAKLOOP_CANCEL_FILE:-${SPEAKLOOP_PAUSE_FILE%.pause}.cancel}"
    if [[ "$PAUSED" == "1" ]]; then
        PAUSED=0; rm -f "$SPOOL/paused"; resume_playback
    fi
    kill_inflight_afplay
    log_lifecycle "cancel: cleared the playback buffer, still listening"
    tmux display-message -t "$PANE_ID" "⛔ Cleared — still listening" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# "repeat": replay the current turn's narration from the beginning, verbatim.
# No model call — this is the words you already heard, again. Clears a standing
# pause, since asking to hear something is an unambiguous request for audio.
do_repeat_turn() {
    if [[ -z "${SPEAKLOOP_PAUSE_FILE:-}" ]]; then
        buzz
        log_lifecycle "repeat: not supported by the old stream mode"
        return 0
    fi
    if [[ "$PAUSED" == "1" ]]; then
        PAUSED=0; rm -f "$SPOOL/paused"; resume_playback
    fi
    : > "${SPEAKLOOP_REPLAYTURN_FILE:-${SPEAKLOOP_PAUSE_FILE%.pause}.replayturn}"
    log_lifecycle "repeat: replaying this turn from the start"
    tmux display-message -t "$PANE_ID" "⟲ Repeating this turn" 2>/dev/null || true
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
    log_lifecycle "play"
    tmux refresh-client -S 2>/dev/null || true
}

# Seeks are chunk-based (~1 chunk ≈ 10-15s of speech): the listener writes a
# command for the player loop and kills the in-flight afplay so it reacts now.
do_forward() {
    # New loop: flush pending narration to catch up to the latest.
    if [[ -n "${SPEAKLOOP_PAUSE_FILE:-}" ]]; then
        : > "${SPEAKLOOP_SKIP_FILE:-${SPEAKLOOP_PAUSE_FILE%.pause}.skip}"
        log_lifecycle "forward: skip to latest (new loop)"
        return 0
    fi
    echo "skip 1" > "$SPOOL/player.cmd"
    kill_inflight_afplay
    log_lifecycle "forward"
}

do_rewind() {
    # "rewind": minus one BLOCK, and it steps — say it twice and you are two
    # blocks back. Distinct from "repeat" (the whole latest agent turn) and from
    # "recap" (a briefing across five turns).
    if [[ -n "${SPEAKLOOP_PAUSE_FILE:-}" ]]; then
        if [[ "$PAUSED" == "1" ]]; then     # replay is an explicit audio request
            PAUSED=0; rm -f "$SPOOL/paused"; resume_playback
        fi
        : > "${SPEAKLOOP_REPLAY_FILE:-${SPEAKLOOP_PAUSE_FILE%.pause}.replay}"
        log_lifecycle "rewind: step back one block"
        return 0
    fi
    echo "back 2" > "$SPOOL/player.cmd"
    kill_inflight_afplay
    log_lifecycle "rewind"
}

# "text box": clear the dictated blob from Claude Code's input. A single
# Ctrl+C clears a non-empty input box, but a Ctrl+C on an ALREADY empty box is
# the first strike of the two-Ctrl+C sequence that quits the Claude REPL — so
# capture the input region first and only send C-c when there's text to clear.
do_clear() {
    if [[ -z "$(capture_input_region)" ]]; then
        log_lifecycle "clear: input already empty, no-op"
        tmux display-message -t "$PANE_ID" "🗑 Input already empty" 2>/dev/null || true
        return 0
    fi
    if tmux send-keys -t "$PANE_ID" C-c 2>/dev/null; then
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
        # Voice-activity signal for the working heartbeat: any real word content
        # (normalize strips whisper's noise annotations like "(crowd cheering)"
        # to empty, so the sticks' own feedback does NOT count) means someone is
        # talking — duck the tick so it stops masking the command in the mic.
        [[ -n "$norm_line" ]] && touch "$SPOOL/voice.active" 2>/dev/null || true
        # Force "send" when a LONE "send" persists across two consecutive reads —
        # the reliable path past the echo guard when the narration keeps saying
        # "send" (see send_lone_prev). Only in the listening state; dictation's
        # own send-end path handles submit there.
        SEND_FORCE=0
        if is_lone_send "$norm_line"; then
            [[ "$send_lone_prev" -eq 1 ]] && SEND_FORCE=1
            send_lone_prev=1
        else
            send_lone_prev=0
        fi
        # The triggered word has left the window once a line arrives without it
        # (alias-aware: transcribe's "subscribe" echo and send's "sent" echo
        # must also keep the guard armed, or the command re-fires on itself).
        #
        # A line whose normalized form is EMPTY does not count. whisper emits
        # "[BLANK_AUDIO]" constantly during silence, and normalize() strips it to
        # nothing — which used to read as "a line without the stem" and disarmed
        # the guard. The trigger word then re-fired on its own echo from whisper's
        # 6s sliding window, so a dictation ended one second after it started:
        #
        #   08:30:29  transcribe trigger: '>> Transcribing.'   <- starts
        #   08:30:30  transcribe-end trigger: 'transcribe.'    <- its own echo
        #   08:30:30  dictation ended: no speech
        #
        # Silence carries no evidence that the word has left the window, so it
        # must leave the latch exactly as it was.
        # ...but the latch MUST also expire on time. Not clearing it on blank
        # lines was right for the few seconds a spoken word keeps reappearing in
        # whisper's sliding window; it was wrong forever after. When the only
        # thing arriving is silence — which is the normal state — the latch
        # never cleared, and the command could never fire again. Observed: four
        # consecutive "transcribe" utterances, hours apart from the last
        # trigger, none of which fired.
        #
        # whisper-stream's window is --length 6000 (6s), so a word cannot still
        # be echoing after that. Past the window the latch has no job left.
        if [[ -n "$echo_stem" ]] \
            && (( SECONDS - echo_stem_at >= STT_WAKE_ECHO_LATCH_SECS )); then
            log_lifecycle "echo latch for '$echo_stem' expired after ${STT_WAKE_ECHO_LATCH_SECS}s"
            echo_stem=""
        fi
        if [[ -n "$echo_stem" && -n "$norm_line" ]] \
            && ! line_has_echo "$norm_line" "$echo_stem"; then
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
                echo_stem="$TRANSCRIBE_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$REPEAT_TURN_STEM" ]] \
                && matches_repeat_turn "$norm_line"; then
                log_lifecycle "repeat-turn trigger: '$line'"
                ack
                debounced "$REPEAT_TURN_STEM" || do_repeat_turn
                echo_stem="$REPEAT_TURN_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$REPEAT_STEM" ]] \
                && matches_word "$norm_line" "$REPEAT_STEM"; then
                log_lifecycle "repeat trigger: '$line'"
                ack
                debounced "$REPEAT_STEM" || do_repeat
                echo_stem="$REPEAT_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$DIGEST_STEM" ]] \
                && matches_word "$norm_line" "$DIGEST_STEM"; then
                log_lifecycle "digest trigger: '$line'"
                ack
                debounced "$DIGEST_STEM" || do_repeat
                echo_stem="$DIGEST_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$SEND_STEM" ]] \
                && { matches_send "$norm_line" || [[ "$SEND_FORCE" == "1" ]]; }; then
                [[ "$SEND_FORCE" == "1" ]] && _how=" (forced: lone send x2)" || _how=""
                log_lifecycle "send trigger: '$line'$_how"
                ack                      # heard you; Hero later means SUBMITTED
                do_send
                echo_stem="$SEND_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$DIAGNOSTIC_STEM" ]] \
                && matches_word "$norm_line" "$DIAGNOSTIC_STEM"; then
                log_lifecycle "diagnostic trigger: '$line'"
                ack
                debounced "$DIAGNOSTIC_STEM" || do_diagnostic
                echo_stem="$DIAGNOSTIC_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$WINDOW_STEM" ]] \
                && matches_word "$norm_line" "$WINDOW_STEM"; then
                # "window" works WHILE the agent is talking — it's an interrupt:
                # moving the mode tears down this pane's playback and switches.
                # (Still blocked during dictation: that's the else-branch below,
                # where the mic is capturing the user's words, not commands.)
                log_lifecycle "window trigger: '$line'"
                ack
                debounced "$WINDOW_STEM" || do_window
                echo_stem="$WINDOW_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$CANCEL_STEM" ]] \
                && matches_word "$norm_line" "$CANCEL_STEM"; then
                log_lifecycle "cancel trigger: '$line'"
                ack
                debounced "$CANCEL_STEM" || do_cancel
                echo_stem="$CANCEL_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$PAUSE_STEM" ]] \
                && matches_exact_word "$norm_line" "$PAUSE_STEM"; then
                log_lifecycle "pause trigger: '$line'"
                ack
                do_pause
                echo_stem="$PAUSE_STEM"; echo_stem_at=$SECONDS
            elif ! player_speaking && [[ "$echo_stem" != "$PLAY_STEM" ]] \
                && matches_exact_word "$norm_line" "$PLAY_STEM"; then
                log_lifecycle "play trigger: '$line'"
                ack
                do_play
                echo_stem="$PLAY_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$FORWARD_STEM" ]] \
                && matches_word "$norm_line" "$FORWARD_STEM"; then
                log_lifecycle "forward trigger: '$line'"
                ack
                debounced "$FORWARD_STEM" || do_forward
                echo_stem="$FORWARD_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$REWIND_STEM" ]] \
                && matches_word "$norm_line" "$REWIND_STEM"; then
                log_lifecycle "rewind trigger: '$line'"
                ack
                debounced "$REWIND_STEM" || do_rewind
                echo_stem="$REWIND_STEM"; echo_stem_at=$SECONDS
            elif ! player_speaking && [[ "$echo_stem" != "$CLEAR_STEM" ]] \
                && matches_clear "$norm_line"; then
                log_lifecycle "clear trigger: '$line'"
                ack
                debounced "$CLEAR_STEM" || do_clear
                echo_stem="$CLEAR_STEM"; echo_stem_at=$SECONDS
            else
                log_near_miss "$norm_line" "$line"
            fi
        else
            if [[ "$echo_stem" != "$TRANSCRIBE_STEM" ]] \
                && matches_transcribe "$norm_line" end; then
                log_lifecycle "transcribe-end trigger: '$line'"
                ack                      # BEFORE transcription, not after it
                end_dictation
                echo_stem="$TRANSCRIBE_STEM"; echo_stem_at=$SECONDS
            elif [[ "$echo_stem" != "$SEND_STEM" ]] \
                && ends_with_send "$norm_line" "$line"; then
                # "send" closes the take AND submits — no second "transcribe".
                log_lifecycle "send-end trigger: '$line'"
                # The dictating branch had no ack at all, which is why "send"
                # felt dead: the first sound was Bottle at t≈2-3s (after a
                # whole-file base.en transcription) and Hero at t≈3-6s. Three
                # seconds of silence after a command reads as failure, so it
                # gets said again — and again. The tone has to be the FIRST
                # thing that happens, before any work.
                ack
                end_dictation "$STT_WAKE_SEND_WORD"
                # do_send now waits for the injected text to settle (BUG-030)
                # and verifies the box cleared, so no separate wait here.
                if [[ "$INJECTED" == "1" ]]; then
                    do_send
                fi
                echo_stem="$SEND_STEM"; echo_stem_at=$SECONDS
            fi
        fi
    fi
    # The cap rolls the take instead of ending it. It used to call
    # end_dictation: recording simply stopped, and every word after that went
    # nowhere. Nothing announced it either, so you find out long afterwards —
    # "the transcription just turns off randomly and I keep talking".
    if [[ "$state" == "dictating" && "$STT_WAKE_MAX_DICTATION" != "0" ]] \
        && (( SECONDS - dict_started > STT_WAKE_MAX_DICTATION )); then
        roll_dictation
    fi
    # A recorder that dies mid-take was completely invisible: state stayed
    # "dictating", the chip still said so, and the microphone was going nowhere.
    # Roll it — that keeps whatever was captured, starts a fresh recorder, and
    # the spoken notice means you learn about it now rather than at the end.
    if [[ "$state" == "dictating" ]]; then
        _rp="$(cat "$REC_PID_FILE" 2>/dev/null)"
        if [[ -n "$_rp" ]] && ! kill -0 "$_rp" 2>/dev/null; then
            log_lifecycle "WARNING: dictation recorder died mid-take; rolling to a fresh one"
            buzz
            announce "recording restarted, please repeat the last sentence"
            roll_dictation
        fi
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
