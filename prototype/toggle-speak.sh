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
    local w; w="$(cat "$RUN/$safe.wake.pid" 2>/dev/null)"
    if [[ -n "$w" ]]; then
        pkill -P "$w" 2>/dev/null || true
        kill -TERM "$w" 2>/dev/null || true
    fi
    pkill -f "whisper-stream .*${safe}\.stream" 2>/dev/null || true
    rm -f "$RUN/$safe.pid" "$RUN/$safe.wake.pid" "$RUN/$safe.pause" \
          "$RUN/$safe.repeat" "$RUN/$safe.skip" "$RUN/$safe.replay"
    rm -rf "$TTS_DIR/$safe.stream" 2>/dev/null || true
    tmux set-option -pt "$pane" -u @speakloop 2>/dev/null || true
    tmux set-option -pt "$pane" -u @speak_on 2>/dev/null || true
    tmux set-option -pt "$pane" -u window-style 2>/dev/null || true
}

if is_running; then
    stop_pane "$PANE_ID"
    tmux display-message "🔇 speak-loop OFF"
    exit 0
fi

command -v python3 >/dev/null 2>&1 || { tmux display-message "speak-loop: python3 not found"; exit 1; }

# Single owner: evict whatever pane currently owns speak mode before we claim it.
PREV="$(cat "$STREAM_PANE" 2>/dev/null)"
[[ -n "$PREV" && "$PREV" != "$SAFE" ]] && stop_pane "%$PREV"

mkdir -p "$SPOOL"
rm -f "$PAUSE_FILE" "$REPEAT_FILE" "$SKIP_FILE" "$REPLAY_FILE"

# --- narration loop (owns repeat/rewind/forward channels) ---
SPEAKLOOP_PAUSE_FILE="$PAUSE_FILE" SPEAKLOOP_REPEAT_FILE="$REPEAT_FILE" \
SPEAKLOOP_SKIP_FILE="$SKIP_FILE" SPEAKLOOP_REPLAY_FILE="$REPLAY_FILE" \
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
    echo "$SAFE" > "$STREAM_PANE"
    SPEAKLOOP_PAUSE_FILE="$PAUSE_FILE" SPEAKLOOP_REPEAT_FILE="$REPEAT_FILE" \
    SPEAKLOOP_SKIP_FILE="$SKIP_FILE" SPEAKLOOP_REPLAY_FILE="$REPLAY_FILE" \
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

# "window" hands off with recap-on-arrival so the user hears where they landed.
[[ "${SPEAKLOOP_RECAP_ON_START:-0}" == "1" ]] && : > "$REPEAT_FILE"

tmux display-message "🔊 speak-loop ON ($PANE_ID · $MODEL) — $HINT"
