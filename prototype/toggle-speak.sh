#!/usr/bin/env bash
# toggle-speak.sh — Ctrl+b o: toggle the tail->rewrite->speak loop for a pane,
# WITH voice commands and the familiar on-screen indicators.
#   1. speak_loop.py    — tails the pane's agent transcript, rewrites each
#                         complete-idea block into speech, plays it. Owns the
#                         repeat/rewind/forward channels too (shared files).
#   2. wake-listener.sh — whisper voice commands: transcribe / send / pause /
#                         play / repeat / rewind / forward / window.
# Speak mode is a SINGLE global owner: starting on any pane stops whatever pane
# owned it before (so only one pane is ever purple). "window" moves the owner
# to the next agent by launching this toggle on that pane.
# Indicators reuse the existing machinery: @speak_on drives the magenta pane
# border + "SPEAKING" chip; stream.pane + <spool>/watcher.pid drive the
# bottom-right status chip (stream-status.sh), which also shows PAUSED/DICTATE.
# Press again to stop everything. Old poll mode is on Ctrl+b O.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
PANE_ID="${1:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
[[ -z "$PANE_ID" ]] && exit 1
SAFE="${PANE_ID#%}"

RUN="/tmp/para-speakloop"; mkdir -p "$RUN"
TTS_DIR="/tmp/para-llm-tts"
STREAM_PANE="$TTS_DIR/stream.pane"
SPOOL="$TTS_DIR/$SAFE.stream"          # shared with stream-status.sh indicators
PIDF="$RUN/$SAFE.pid"
WAKE_PIDF="$RUN/$SAFE.wake.pid"
PAUSE_FILE="$RUN/$SAFE.pause"
REPEAT_FILE="$RUN/$SAFE.repeat"
SKIP_FILE="$RUN/$SAFE.skip"
REPLAY_FILE="$RUN/$SAFE.replay"
CANCEL_FILE="$RUN/$SAFE.cancel"
LOG="$RUN/$SAFE.log"

MODEL="${TTS_STREAM_REWRITE_MODEL:-haiku}"
ENGINE="${SPEAKLOOP_ENGINE:-edge}"
SPEAK_TINT="${SPEAKLOOP_TINT-#3a2044}"

# Friendly chip label: the para-llm env name, else git branch, else dir name.
resolve_label() {
    local p label=""
    p="$(tmux display-message -pt "$PANE_ID" '#{pane_current_path}' 2>/dev/null)"
    case "$p" in
        */envs/*) label="${p#*/envs/}"; label="${label%%/*}" ;;
    esac
    [[ -z "$label" && -n "$p" ]] && label="$(git -C "$p" branch --show-current 2>/dev/null)"
    [[ -z "$label" && -n "$p" ]] && label="${p##*/}"
    [[ -z "$label" ]] && label="pane $SAFE"
    printf '%s' "${label:0:24}"
}

is_running() { local p; p="$(cat "$PIDF" 2>/dev/null)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

# Fully tear down the speak-mode stack for ANY pane (loop + wake-listener +
# whisper + indicators + spool). Used both for the toggle-off path and to
# evict the previous owner when speak mode moves.
stop_pane() {
    local pane="$1" safe="${1#%}"
    local p; p="$(cat "$RUN/$safe.pid" 2>/dev/null)"
    if [[ -n "$p" ]]; then
        kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
        sleep 0.3
        kill -KILL "-$p" 2>/dev/null || true
    fi
    [[ "$(cat "$STREAM_PANE" 2>/dev/null)" == "$safe" ]] && rm -f "$STREAM_PANE" 2>/dev/null || true
    # TERM the wake-listener; its own trap reaps whisper/rec. Deliberately NOT
    # `pkill -P "$w"` — when this runs from a toggle launched by "window", that
    # toggle can be a child of the wake-listener and would kill itself.
    local w; w="$(cat "$RUN/$safe.wake.pid" 2>/dev/null)"
    [[ -n "$w" ]] && kill -TERM "$w" 2>/dev/null || true
    pkill -f "whisper-stream .*${safe}\.stream" 2>/dev/null || true
    # NOTE: `say` is deliberately NOT killed here — see the toggle-off branch.
    # stop_pane has two callers with opposite needs, and killing `say` in the
    # shared path silenced the "window" announcement (BUG-038).
    rm -f "$RUN/$safe.pid" "$RUN/$safe.wake.pid" "$RUN/$safe.pause" \
          "$RUN/$safe.repeat" "$RUN/$safe.skip" "$RUN/$safe.replay" \
          "$RUN/$safe.cancel"
    rm -rf "$TTS_DIR/$safe.stream" 2>/dev/null || true
    tmux set-option -pt "$pane" -u @speakloop 2>/dev/null || true
    tmux set-option -pt "$pane" -u @speak_on 2>/dev/null || true
    tmux set-option -pt "$pane" -u window-style 2>/dev/null || true
}

if is_running; then
    stop_pane "$PANE_ID"
    # Silence a detached announcement ONLY when the user is turning speak mode
    # off. "Off" means quiet now, including a `say` still mid-word.
    #
    # This must NOT live in stop_pane, which has two callers with opposite
    # needs: this one (toggle off -> kill it) and the eviction below (a "window"
    # hand-off -> the announcement for the pane you are moving TO was started
    # milliseconds ago and must survive). Putting the kill in the shared path
    # killed a 4-second announcement within milliseconds of it starting, so
    # "window" stopped saying where you landed (BUG-038).
    pkill -x say 2>/dev/null || true
    tmux display-message "🔇 speak-loop OFF"
    exit 0
fi

command -v python3 >/dev/null 2>&1 || { tmux display-message "speak-loop: python3 not found"; exit 1; }

# Single owner: evict whatever pane currently owns speak mode before we claim it.
# Read-evict-claim must be ATOMIC. It used to be three unsynchronized steps with
# the claim 25 lines further down, so two overlapping hand-offs both read the
# same previous owner, both evicted it, and both survived — leaving a narration
# loop running for a pane that no longer had the purple. Saying a command twice
# because it seemed not to work is exactly what produced that overlap.
#
# mkdir is the atomic primitive available in POSIX shell: it succeeds for exactly
# one racer. The loser waits, then reads a stream.pane the winner has already
# written, so it evicts the RIGHT pane instead of a stale one.
CLAIM_LOCK="$TTS_DIR/claim.lock"
mkdir -p "$TTS_DIR"
_locked=0
for _ in $(seq 1 100); do                 # ~5s ceiling, then proceed anyway
    if mkdir "$CLAIM_LOCK" 2>/dev/null; then _locked=1; break; fi
    # A lock older than 30s is a crashed toggle, not a live one.
    if [[ -d "$CLAIM_LOCK" ]] && [[ -n "$(find "$CLAIM_LOCK" -maxdepth 0 -mmin +0.5 2>/dev/null)" ]]; then
        rmdir "$CLAIM_LOCK" 2>/dev/null || true
    fi
    sleep 0.05
done

PREV="$(cat "$STREAM_PANE" 2>/dev/null)"
[[ -n "$PREV" && "$PREV" != "$SAFE" ]] && stop_pane "%$PREV"
# Claim NOW, inside the lock — not later inside the whisper branch. The
# narration loop watches this file to decide whether it still owns the mode, so
# it has to name the owner even when whisper/sox are absent.
echo "$SAFE" > "$STREAM_PANE"
[[ "$_locked" == "1" ]] && rmdir "$CLAIM_LOCK" 2>/dev/null || true

mkdir -p "$SPOOL"
rm -f "$PAUSE_FILE" "$REPEAT_FILE" "$SKIP_FILE" "$REPLAY_FILE" "$CANCEL_FILE"

# --- narration loop (owns repeat/rewind/forward channels) ---
SPEAKLOOP_PAUSE_FILE="$PAUSE_FILE" SPEAKLOOP_REPEAT_FILE="$REPEAT_FILE" \
SPEAKLOOP_SKIP_FILE="$SKIP_FILE" SPEAKLOOP_REPLAY_FILE="$REPLAY_FILE" \
SPEAKLOOP_CANCEL_FILE="$CANCEL_FILE" \
TTS_STREAM_REWRITE_MODEL="$MODEL" \
    nohup python3 "$DIR/speak_loop.py" "$PANE_ID" \
        --backlog 0 --model "$MODEL" --engine "$ENGINE" > "$LOG" 2>&1 &
SPEAK_PID=$!
echo "$SPEAK_PID" > "$PIDF"

# indicator state read by stream-status.sh (bottom-right chip): a live
# watcher.pid + a label under the shared spool, plus stream.pane below.
echo "$SPEAK_PID" > "$SPOOL/watcher.pid"
resolve_label > "$SPOOL/label"

# --- voice commands via the existing wake-listener ---
if command -v whisper-stream >/dev/null 2>&1 && command -v rec >/dev/null 2>&1; then
    mkdir -p "$TTS_DIR"
    rm -f "$TTS_DIR/keepalive" 2>/dev/null || true   # stop old keeper reviving old workers
    SPEAKLOOP_PAUSE_FILE="$PAUSE_FILE" SPEAKLOOP_REPEAT_FILE="$REPEAT_FILE" \
    SPEAKLOOP_SKIP_FILE="$SKIP_FILE" SPEAKLOOP_REPLAY_FILE="$REPLAY_FILE" \
    SPEAKLOOP_CANCEL_FILE="$CANCEL_FILE" \
        nohup bash "$ROOT/plugins/stt/wake-listener.sh" "$PANE_ID" "$SPOOL" \
            > "$RUN/$SAFE.wake.log" 2>&1 &
    echo $! > "$WAKE_PIDF"
    HINT="transcribe / send / pause / play / repeat / rewind / forward / window"
else
    HINT="narration only (whisper/sox missing)"
fi

# indicators: @speak_on -> magenta border + "SPEAKING" chip (existing global
# format); window tint -> purple background.
tmux set-option -pt "$PANE_ID" @speakloop 1 2>/dev/null || true
tmux set-option -pt "$PANE_ID" @speak_on 1 2>/dev/null || true
[[ -n "$SPEAK_TINT" ]] && tmux set-option -pt "$PANE_ID" window-style "bg=$SPEAK_TINT" 2>/dev/null || true

# Catch-up on start: optionally speak a briefing of the previous turn(s) before
# live narration begins. Default OFF for a manual Ctrl+b o — the user wants to
# just start listening and hear future messages as they arrive, and can ask for
# a recap any time by saying "repeat". The "window" hand-off still passes
# SPEAKLOOP_RECAP_ON_START=1 so moving to another agent tells you where it landed.
[[ "${SPEAKLOOP_RECAP_ON_START:-0}" == "1" ]] && : > "$REPEAT_FILE"

tmux display-message "🔊 speak-loop ON ($PANE_ID · $MODEL) — $HINT"
