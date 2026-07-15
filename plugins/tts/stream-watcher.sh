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
export TTS_STREAM_FLUSH_SECS="${TTS_STREAM_FLUSH_SECS:-4}"
export TTS_STREAM_REWRITE="${TTS_STREAM_REWRITE:-1}"

# Attention chimes: when the bound pane's Claude transitions to "ready for
# input" or "needs action" (permission prompt / question), play a sound so
# headphone users know without watching the pane. Uses the claude-state
# monitor's per-pane display files. Empty sound path disables.
TTS_STREAM_READY_SOUND="${TTS_STREAM_READY_SOUND-/System/Library/Sounds/Ping.aiff}"
TTS_STREAM_ACTION_SOUND="${TTS_STREAM_ACTION_SOUND-/System/Library/Sounds/Funk.aiff}"
# 0.4s: a line must survive two consecutive polls to be spoken, and in small
# command-center tiles (~15 rows on the alternate screen) prose can scroll out
# of the viewport within a couple of seconds of a tool block rendering.
POLL_INTERVAL="${TTS_STREAM_POLL_INTERVAL:-0.4}"

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
    for f in "$SPOOL/synth.pid" "$SPOOL/player.pid" "$SPOOL/framing.pid" "$SPOOL/rewrite.pid" "$SPOOL/wake.pid" "$SPOOL/whisper-stream.pid" "$SPOOL/dictation-rec.pid"; do
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
        *)                      echo other ;;
    esac
}

LAST_PANE_STATE=""
LAST_CHIME=0
maybe_chime_state() {
    local now_state
    now_state="$(pane_state)"
    if [[ "$now_state" != "$LAST_PANE_STATE" ]]; then
        # Skip the very first observation (enabling the mode on an idle pane
        # should not chime) and debounce flappy transitions.
        if [[ -n "$LAST_PANE_STATE" ]] && (( SECONDS - LAST_CHIME >= 10 )); then
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
        LAST_PANE_STATE="$now_state"
    fi
}

# The mode file is written shortly AFTER we are spawned (see toggle-stream.sh
# start order) — wait briefly for it instead of exiting on a not-yet-on mode.
tries=0
until mode_active; do
    tries=$((tries + 1))
    [[ "$tries" -gt 20 ]] && exit 0
    sleep 0.1
done

while mode_active; do
    if ! pane_alive; then
        teardown_dead_pane
        exit 0
    fi

    tmux capture-pane -t "$PANE_ID" -p -S - 2>/dev/null \
        | "$SCRIPT_DIR/filter-pane-text.sh" > "$SPOOL/cur.txt.part" \
        && mv "$SPOOL/cur.txt.part" "$SPOOL/cur.txt"

    if ! python3 "$SCRIPT_DIR/stream-step.py" "$SPOOL" 2>> "$SPOOL/error.log"; then
        printf '%s  stream-step.py failed\n' "$(date '+%H:%M:%S')" >> "$SPOOL/error.log"
    fi

    maybe_chime_state
    sleep "$POLL_INTERVAL"
done
