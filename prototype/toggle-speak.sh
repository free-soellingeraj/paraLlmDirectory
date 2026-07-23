#!/usr/bin/env bash
# toggle-speak.sh — Ctrl+b o: toggle the prototype tail->rewrite->speak loop
# for a pane. Starts speak_loop.py (which tails the pane's agent transcript,
# rewrites each complete-idea chunk into speech, and plays it). Press again to
# stop. Replaces the old poll-based speak mode (still on Ctrl+b O as a fallback).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANE_ID="${1:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
[[ -z "$PANE_ID" ]] && exit 1
SAFE="${PANE_ID#%}"
RUN="/tmp/para-speakloop"; mkdir -p "$RUN"
PIDF="$RUN/$SAFE.pid"
LOG="$RUN/$SAFE.log"

MODEL="${TTS_STREAM_REWRITE_MODEL:-haiku}"
ENGINE="${SPEAKLOOP_ENGINE:-edge}"

is_running() { local p; p="$(cat "$PIDF" 2>/dev/null)"; [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

stop() {
    local p; p="$(cat "$PIDF" 2>/dev/null)"
    if [[ -n "$p" ]]; then
        # speak_loop calls setsid, so its pid is its process-group id — kill the
        # whole tree (python + tail + edge-tts + afplay) in one shot.
        kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
        sleep 0.3
        kill -KILL "-$p" 2>/dev/null || true
    fi
    rm -f "$PIDF"
    tmux set-option -pt "$PANE_ID" -u @speakloop 2>/dev/null || true
}

if is_running; then
    stop
    tmux display-message "🔇 speak-loop OFF"
    exit 0
fi

# Don't fight the old poll-based speak mode over the one audio channel.
rm -f /tmp/para-llm-tts/stream.pane 2>/dev/null || true

if ! command -v python3 >/dev/null 2>&1; then
    tmux display-message "speak-loop: python3 not found"; exit 1
fi

TTS_STREAM_REWRITE_MODEL="$MODEL" \
    nohup python3 "$DIR/speak_loop.py" "$PANE_ID" \
        --backlog 0 --model "$MODEL" --engine "$ENGINE" > "$LOG" 2>&1 &
echo $! > "$PIDF"
tmux set-option -pt "$PANE_ID" @speakloop 1 2>/dev/null || true
tmux display-message "🔊 speak-loop ON ($PANE_ID · $MODEL) — narrates from now"
