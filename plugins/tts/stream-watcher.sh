#!/usr/bin/env bash
# stream-watcher.sh - speak mode's capture loop.
# Polls the bound pane, filters chrome, and runs stream-step.py to turn newly
# settled transcript lines into synthesis chunks. Started by toggle-stream.sh.
#
# Usage: stream-watcher.sh <pane_id> <spool_dir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANE_ID="${1:?usage: stream-watcher.sh <pane_id> <spool_dir>}"
SPOOL="${2:?usage: stream-watcher.sh <pane_id> <spool_dir>}"

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

export TTS_SYNTH_CHARS="${TTS_SYNTH_CHARS:-180}"
export TTS_STREAM_PAUSE_SECS="${TTS_STREAM_PAUSE_SECS:-3}"
export TTS_STREAM_MAX_PENDING="${TTS_STREAM_MAX_PENDING:-1500}"
# Scriptify: pause-batched blocks are coherent thoughts, worth the codex
# rewrite (30-60s per block; falls back to raw pass-through on failure).
export TTS_STREAM_REWRITE="${TTS_STREAM_REWRITE:-1}"

# Attention chimes: when the bound pane's Claude transitions to "ready for
# input" or "needs action" (permission prompt / question), play a sound so
# headphone users know without watching the pane. Uses the claude-state
# monitor's per-pane display files. Empty sound path disables.
TTS_STREAM_READY_SOUND="${TTS_STREAM_READY_SOUND-/System/Library/Sounds/Ping.aiff}"
TTS_STREAM_ACTION_SOUND="${TTS_STREAM_ACTION_SOUND-/System/Library/Sounds/Funk.aiff}"

# Working "heartbeat": a soft cricket loop while the bound pane's Claude is
# actively working AND the voice is silent — it fills the thinking gap after
# you send so you know the prompt landed and you needn't say "send" again. It
# ducks out for narration and dictation (below). Empty sound path or
# TTS_STREAM_WORKING_ENABLED=0 disables. Sound is synthesized with sox into
# $TTS_DIR the first time; set TTS_STREAM_WORKING_SOUND to your own file to
# override (a "sticks" alternate is generated alongside for easy swapping).
TTS_STREAM_WORKING_ENABLED="${TTS_STREAM_WORKING_ENABLED:-1}"
TTS_STREAM_WORKING_SOUND="${TTS_STREAM_WORKING_SOUND:-}"
TTS_STREAM_WORKING_VOLUME="${TTS_STREAM_WORKING_VOLUME:-1}"
TTS_STREAM_WORKING_GAP="${TTS_STREAM_WORKING_GAP:-1.1}"
# 0.4s: a line must survive two consecutive polls to be spoken, and in small
# command-center tiles (~15 rows on the alternate screen) prose can scroll out
# of the viewport within a couple of seconds of a tool block rendering.
POLL_INTERVAL="${TTS_STREAM_POLL_INTERVAL:-0.4}"

# "digest" (default): stay quiet while the agent works, then speak a codex
# summary of the whole turn ("You asked X; the agent did Y") when the pane
# transitions to ready — nothing gets chopped by freshness skipping and the
# voice is silent while you think. "stream": the sentence-by-sentence live
# narration (freshness-capped, may skip under firehose output).
TTS_STREAM_MODE="${TTS_STREAM_MODE:-stream}"

source "$SCRIPT_DIR/tts-lib.sh"

mode_active() {
    [[ "$(cat "$STREAM_PANE_FILE" 2>/dev/null)" == "$SAFE_PANE_ID" ]]
}

# display-message -t exits 0 even for a dead pane (it falls back to another
# target), so liveness needs an exact match against the real pane list. The
# list is captured into a variable first: piping tmux straight into grep -q
# can kill tmux with SIGPIPE, and under pipefail that reads as "pane dead".
pane_alive() {
    local panes
    panes="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
    grep -qx "$PANE_ID" <<< "$panes"
}

# Lifecycle events go to a persistent log OUTSIDE the spool — teardown deletes
# the spool, which would otherwise destroy the evidence of why it ran.
log_lifecycle() {
    printf '%s  watcher[%s]  %s\n' "$(date '+%F %T')" "$PANE_ID" "$*" \
        >> "$TTS_DIR/stream.log" 2>/dev/null || true
}

# If the bound pane disappears, tear the whole mode down (workers exit once
# stream.pane is gone) so a closed window can't leave orphan loops behind.
teardown_dead_pane() {
    log_lifecycle "teardown: pane no longer in list-panes (panes now: $(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | tr '\n' ' '))"
    if mode_active; then
        rm -f "$STREAM_PANE_FILE"
    fi
    # The pane is gone so its options usually died with it, but unmark anyway
    # in case the id was reused — a stale @speak_on/tint would mark a random pane.
    tmux set-option -pt "$PANE_ID" -u @speak_on 2>/dev/null || true
    tmux set-option -pt "$PANE_ID" -u window-style 2>/dev/null || true
    local f pid
    for f in "$SPOOL/synth.pid" "$SPOOL/player.pid" "$SPOOL/framing.pid" "$SPOOL/rewrite.pid" "$SPOOL/wake.pid" "$SPOOL/whisper-stream.pid" "$SPOOL/dictation-rec.pid" "$SPOOL/working-sound.pid"; do
        pid="$(cat "$f" 2>/dev/null)"
        [[ -n "$pid" ]] && kill_tree "$pid"
        rm -f "$f"
    done
    local active_file="$TTS_DIR/active.pane"
    if [[ "$(cat "$active_file" 2>/dev/null)" == "$SAFE_PANE_ID" ]]; then
        rm -f "$active_file"
    fi
    rm -rf "$SPOOL"
    tmux refresh-client -S 2>/dev/null || true
}

# Classify the bound pane's Claude state from the state monitor's display
# file (e.g. "#[fg=green]Waiting for Input | repo | branch#[default]").
pane_state() {
    local f content=""
    for f in "${PARA_LLM_ROOT:-$HOME/.para-llm-directory}/recovery/pane-display/$SAFE_PANE_ID" \
             "/tmp/claude-pane-display/$SAFE_PANE_ID"; do
        [[ -f "$f" ]] && { content="$(cat "$f" 2>/dev/null)"; break; }
    done
    case "$content" in
        *"Needs Action"*)       echo action ;;
        *"Waiting for Input"*)  echo ready ;;
        *"Working"*)            echo working ;;
        *)                      echo other ;;
    esac
}

# True when the agent is actively working. Prefers the state monitor; when it
# has no opinion (monitor not running for this pane), falls back to the live
# capture — Claude Code shows a spinner and an "esc to interrupt" hint only
# while a turn runs. Deliberately conservative: unknown state => not working,
# so the heartbeat never chirps on an idle pane just because the monitor is off.
# Authoritative per-pane state PUBLISHED BY CLAUDE CODE ITSELF: its hooks
# (PreToolUse/PostToolUse/Stop/Notification) run state-tracker.sh, which writes
# a JSON state file keyed by the session cwd. `.state` is one of working /
# ready / blocked (permission prompt) / ended / starting. This is event-driven
# truth, not screen-scraping — in particular a permission prompt is `blocked`,
# so we don't have to pattern-match dialog chrome to stay quiet for it.
# Returns the state string, or "" when no hook file exists (hooks not
# installed for this session — we degrade to the screen heuristic below).
hook_state() {
    local cwd safe f
    cwd="$(tmux display-message -pt "$PANE_ID" '#{pane_current_path}' 2>/dev/null)"
    [[ -n "$cwd" ]] || return 0
    safe="$(printf '%s' "$cwd" | sed 's|/|_|g; s|^_||')"
    f="/tmp/claude-state/by-cwd/$safe.json"
    [[ -f "$f" ]] || return 0
    grep -o '"state"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/'
}

# "A turn is actively running right now" — Claude Code shows "esc to interrupt"
# in its bottom status bar only while working; absent at an idle prompt. This
# is the ONE piece of screen text we still read, and it's the same signal the
# project's own state-detector and Claude's idle-notification hook key on.
# Scope to the last non-blank lines so scrollback transcript (which quotes
# "esc to interrupt" — like this very conversation) can never match.
footer_running() {
    grep -vE '^[[:space:]]*$' "$SPOOL/cur.raw" 2>/dev/null | tail -4 \
        | grep -qF 'esc to interrupt'
}

# No-hooks fallback only: recognise a user-blocking dialog from its chrome.
awaiting_user() {
    local tail
    tail="$(grep -vE '^[[:space:]]*$' "$SPOOL/cur.raw" 2>/dev/null | tail -14)"
    grep -qE 'Do you want to|Do you trust|Would you like to proceed|No, and tell Claude|don.t ask again|❯[[:space:]]+[0-9]+\.' <<< "$tail"
}

is_working() {
    case "$(hook_state)" in
        # Authoritative "it's the user's turn" / finished — always silent.
        # `blocked` is the permission/trust/plan prompt; no chrome matching.
        blocked|ended) return 1 ;;
        # No hook state for this session: fall back to the screen heuristic
        # (footer + the dialog patterns) for everything.
        "") awaiting_user && return 1 ;;
    esac
    # Otherwise a turn is running iff Claude's own status bar says so. Using
    # the live footer here (not the hook's working/ready) makes us robust to
    # BOTH the unreliable Stop hook (stale "working" — the footer will have
    # cleared) and the missing UserPromptSubmit hook (initial thinking shows
    # as stale "ready" — the footer already shows the turn running).
    footer_running
}

# Synthesize the heartbeat sounds into $TTS_DIR once (shared across panes /
# boots). Sets WORKING_SOUND_FILE to the chosen file, or "" if unavailable.
WORKING_SOUND_FILE=""
ensure_working_sound() {
    if [[ -n "$TTS_STREAM_WORKING_SOUND" ]]; then
        WORKING_SOUND_FILE="$TTS_STREAM_WORKING_SOUND"
        return 0
    fi
    command -v sox >/dev/null 2>&1 || { WORKING_SOUND_FILE=""; return 0; }
    # -t wav forces the container: sox picks the encoder from the extension,
    # and the atomic ".part" temp would otherwise read as an unknown type.
    local cricket="$TTS_DIR/working-cricket.wav" sticks="$TTS_DIR/working-sticks.wav"
    if [[ ! -s "$cricket" ]]; then
        sox -n -r 44100 -c 1 -t wav "$cricket.part" \
            synth 0.5 sine 4600 tremolo 55 90 fade t 0.02 0.5 0.12 gain -20 2>/dev/null \
            && mv "$cricket.part" "$cricket" 2>/dev/null || rm -f "$cricket.part"
    fi
    if [[ ! -s "$sticks" ]]; then
        sox -n -r 44100 -c 1 -t wav "$sticks.part" \
            synth 0.28 brownnoise tremolo 28 100 bandpass 2600 1.5q fade t 0.02 0.28 0.1 gain -12 2>/dev/null \
            && mv "$sticks.part" "$sticks" 2>/dev/null || rm -f "$sticks.part"
    fi
    # Default is the drier "sticks rubbing" scrape (user preference): it reads
    # as ambient texture, not an alarm. The tonal cricket is the alternate.
    [[ -s "$sticks" ]] && WORKING_SOUND_FILE="$sticks" \
        || { [[ -s "$cricket" ]] && WORKING_SOUND_FILE="$cricket" || WORKING_SOUND_FILE=""; }
}

CHIRP_PID_FILE="$SPOOL/working-sound.pid"
chirp_running() {
    local pid; pid="$(cat "$CHIRP_PID_FILE" 2>/dev/null)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}
chirp_start() {
    chirp_running && return 0
    [[ -n "$WORKING_SOUND_FILE" && -f "$WORKING_SOUND_FILE" ]] || return 0
    command -v afplay >/dev/null 2>&1 || return 0
    (
        while :; do
            afplay -v "$TTS_STREAM_WORKING_VOLUME" "$WORKING_SOUND_FILE" >/dev/null 2>&1 || sleep 1
            sleep "$TTS_STREAM_WORKING_GAP"
        done
    ) &
    echo "$!" > "$CHIRP_PID_FILE"
}
chirp_stop() {
    local pid; pid="$(cat "$CHIRP_PID_FILE" 2>/dev/null)"
    [[ -n "$pid" ]] && kill_tree "$pid"
    rm -f "$CHIRP_PID_FILE"
}

# True while the player has an afplay in flight — the voice is speaking, so
# the heartbeat ducks out (same test wake-listener uses for feedback).
player_speaking_now() {
    local pid; pid="$(cat "$SPOOL/player.pid" 2>/dev/null)"
    [[ -n "$pid" ]] && pgrep -P "$pid" -x afplay >/dev/null 2>&1
}

# Start/stop the heartbeat each tick. Chirps only when working AND nothing
# else should own the audio: not paused, not dictating (mic is open — the
# chirp would leak into whisper), not while the voice is speaking.
maybe_working_sound() {
    [[ "$TTS_STREAM_WORKING_ENABLED" == "0" ]] && { chirp_stop; return 0; }
    local want=1
    is_working || want=0
    [[ -f "$SPOOL/paused" ]] && want=0
    [[ "$(cat "$SPOOL/wake.state" 2>/dev/null)" == "dictating" ]] && want=0
    # Recap/digest prep owns the audio and plays the SAME sound itself
    # (stream-framing) — suppress here so the two never double up.
    [[ -f "$SPOOL/framing.lock" ]] && want=0
    player_speaking_now && want=0
    # Duck while the wake-listener just heard a real word: the tick feeds back
    # into the mic and masks voice commands ("send" heard as noise). The
    # listener touches voice.active on any non-annotation whisper output.
    if [[ -f "$SPOOL/voice.active" ]]; then
        local va_age
        va_age=$(( $(date +%s) - $(stat -f %m "$SPOOL/voice.active" 2>/dev/null || stat -c %Y "$SPOOL/voice.active" 2>/dev/null || echo 0) ))
        (( va_age < 3 )) && want=0
    fi
    if [[ "$want" == 1 ]]; then chirp_start; else chirp_stop; fi
}

# Digest mode: when a turn completes (pane held a working state >=10s, then
# turned ready), summarize the whole turn and speak it. Reuses the framing
# pipeline; the lock gates any stream emission while the digest prepares.
trigger_digest() {
    local fpid
    fpid="$(cat "$SPOOL/framing.pid" 2>/dev/null)"
    if [[ -n "$fpid" ]] && kill -0 "$fpid" 2>/dev/null; then
        return 0
    fi
    log_lifecycle "digest: turn completed, summarizing"
    touch "$SPOOL/framing.lock"
    TTS_STREAM_RECAP_CHARS="${TTS_STREAM_DIGEST_CHARS:-900}" \
        nohup "$SCRIPT_DIR/stream-framing.sh" "$PANE_ID" "$SPOOL" >/dev/null 2>&1 &
    echo "$!" > "$SPOOL/framing.pid"
}

LAST_PANE_STATE=""
STATE_SINCE=0
LAST_CHIME=0
maybe_chime_state() {
    local now_state
    now_state="$(pane_state)"
    if [[ "$now_state" != "$LAST_PANE_STATE" ]]; then
        local prev="$LAST_PANE_STATE" held=$((SECONDS - STATE_SINCE))
        LAST_PANE_STATE="$now_state"
        STATE_SINCE=$SECONDS
        # Skip the very first observation (enabling the mode on an idle pane
        # should not chime) and debounce flappy transitions.
        [[ -n "$prev" ]] || return 0
        if (( SECONDS - LAST_CHIME >= 10 )); then
            local sound=""
            case "$now_state" in
                ready)  sound="$TTS_STREAM_READY_SOUND" ;;
                action) sound="$TTS_STREAM_ACTION_SOUND" ;;
            esac
            if [[ -n "$sound" && -f "$sound" ]] && command -v afplay >/dev/null 2>&1; then
                afplay "$sound" >/dev/null 2>&1 &
                LAST_CHIME=$SECONDS
            fi
        fi
        if [[ "$TTS_STREAM_MODE" == "digest" && "$now_state" == "ready" \
            && "$prev" != "ready" && "$held" -ge 10 ]]; then
            trigger_digest
        fi
    fi
}

# The heartbeat loop is our child; never leave it chirping after we exit.
trap 'chirp_stop 2>/dev/null' EXIT

# The mode file is written shortly AFTER we are spawned (see toggle-stream.sh
# start order) — wait briefly for it instead of exiting on a not-yet-on mode.
tries=0
until mode_active; do
    tries=$((tries + 1))
    [[ "$tries" -gt 20 ]] && exit 0
    sleep 0.1
done

ensure_working_sound

while mode_active; do
    if ! pane_alive; then
        teardown_dead_pane
        exit 0
    fi

    # Raw capture feeds both the filtered transcript AND is_working's spinner
    # fallback, so we snapshot the pane once per tick.
    tmux capture-pane -t "$PANE_ID" -p -S - 2>/dev/null > "$SPOOL/cur.raw.part" \
        && mv "$SPOOL/cur.raw.part" "$SPOOL/cur.raw"

    if [[ "$TTS_STREAM_MODE" != "digest" ]]; then
        "$SCRIPT_DIR/filter-pane-text.sh" < "$SPOOL/cur.raw" > "$SPOOL/cur.txt.part" \
            && mv "$SPOOL/cur.txt.part" "$SPOOL/cur.txt"

        if ! python3 "$SCRIPT_DIR/stream-step.py" "$SPOOL" 2>> "$SPOOL/error.log"; then
            printf '%s  stream-step.py failed\n' "$(date '+%H:%M:%S')" >> "$SPOOL/error.log"
        fi
    fi

    maybe_chime_state
    maybe_working_sound
    sleep "$POLL_INTERVAL"
done
