#!/usr/bin/env bash
# Toggle speak mode (streaming text-to-speech) for a tmux pane.
# Called by tmux key binding: Ctrl+b o   (overrides tmux's default "next pane")
#
# Speak mode is bound to exactly one pane at a time:
#   - press in an unbound pane: mode turns ON for that pane (moving it here if
#     it was bound to another pane)
#   - press in the bound pane:  mode turns OFF
#
# While on, three workers cooperate through /tmp/para-llm-tts/<pane>.stream/:
#   stream-watcher.sh  polls the pane and emits settled sentences as chunks
#   stream-synth.sh    turns chunks into audio (edge-tts, `say` fallback)
#   stream-player.sh   plays audio strictly in order
#
# Usage: toggle-stream.sh [pane_id]   (pane_id defaults to the active pane)

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

TTS_STREAM_ENGINE="${TTS_STREAM_ENGINE:-edge-tts}"

source "$SCRIPT_DIR/tts-lib.sh"

PANE_ID="${1:-}"
if [[ -z "$PANE_ID" ]]; then
    PANE_ID="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
fi
if [[ -z "$PANE_ID" ]]; then
    exit 1
fi
SAFE_PANE_ID="${PANE_ID#%}"

STREAM_PANE_FILE="$TTS_DIR/stream.pane"
ACTIVE_FILE="$TTS_DIR/active.pane"
TOGGLE_LOCK="$TTS_DIR/stream.toggle.lock"

spool_for() {
    echo "$TTS_DIR/$1.stream"
}

# Lifecycle events persist outside the spool (teardown deletes the spool).
log_lifecycle() {
    printf '%s  toggle[%s]  %s\n' "$(date '+%F %T')" "$PANE_ID" "$*" \
        >> "$TTS_DIR/stream.log" 2>/dev/null || true
}

# Human-meaningful name for the bound pane, resolved ONCE at enable time while
# the pane is guaranteed alive. The ENV DIRECTORY name comes first — it's how
# panes are identified in this workflow and it's stable; the checked-out git
# branch is NOT (agents switch branches inside the worktree mid-session, which
# made the chip show a branch nobody recognized). The status script reads the
# stored result — re-deriving it later through a dead pane id would silently
# read a DIFFERENT pane (display-message falls back instead of failing).
resolve_label() {
    local pane_path label=""
    pane_path="$(tmux display-message -pt "$PANE_ID" '#{pane_current_path}' 2>/dev/null)"
    case "$pane_path" in
        */envs/*) label="${pane_path#*/envs/}"; label="${label%%/*}" ;;
    esac
    [[ -z "$label" ]] && label="$(git -C "$pane_path" branch --show-current 2>/dev/null)"
    [[ -z "$label" && -n "$pane_path" ]] && label="${pane_path##*/}"
    [[ -z "$label" ]] && label="pane $SAFE_PANE_ID"
    echo "${label:0:24}"
}

# Serialize concurrent prefix-o presses; mkdir is atomic.
acquire_toggle_lock() {
    local tries=0
    while ! mkdir "$TOGGLE_LOCK" 2>/dev/null; do
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
trap release_toggle_lock EXIT

# Bound-pane indicator, three layers:
#   1. @speak_on (true pane-scoped user option) drives the "🔊 SPEAKING" chip
#      and magenta border via GLOBAL pane-border-format/style conditionals
#      (see install.sh) — pane-border-style is a window option, so setting it
#      "per pane" here would paint every border in the window (BUG-021).
#   2. A purple background tint on the pane content itself (select-pane -P →
#      per-pane window-style). Tiled borders are SHARED between neighbours and
#      get overpainted when focus moves, so the border alone stops marking the
#      pane the moment you click elsewhere — the tint is focus-independent.
# Pane options vanish with the pane, so death cleanup is automatic.
SPEAK_TINT="${TTS_STREAM_TINT-#3a2044}"   # set TTS_STREAM_TINT="" to disable

mark_pane() {
    local pane="$1"
    tmux set-option -pt "$pane" @speak_on 1 2>/dev/null || true
    # window-style IS pane-scoped (verified: does not leak to window scope).
    # set-option rather than select-pane -P, which can also move focus.
    if [[ -n "$SPEAK_TINT" ]]; then
        tmux set-option -pt "$pane" window-style "bg=$SPEAK_TINT" 2>/dev/null || true
    fi
}

unmark_pane() {
    local pane="$1"
    tmux set-option -pt "$pane" -u @speak_on 2>/dev/null || true
    tmux set-option -pt "$pane" -u window-style 2>/dev/null || true
}

stop_stream_for_pane() {
    local safe="$1"
    local spool
    spool="$(spool_for "$safe")"
    unmark_pane "%$safe"

    # Clearing stream.pane first lets the worker loops exit on their own even
    # if a PID file went missing; kill_tree then stops them (and any afplay
    # mid-utterance) immediately.
    if [[ "$(cat "$STREAM_PANE_FILE" 2>/dev/null)" == "$safe" ]]; then
        rm -f "$STREAM_PANE_FILE"
    fi

    local f pid
    for f in "$spool/watcher.pid" "$spool/synth.pid" "$spool/player.pid"; do
        pid="$(cat "$f" 2>/dev/null)"
        [[ -n "$pid" ]] && kill_tree "$pid"
    done
    rm -rf "$spool"

    if [[ "$(cat "$ACTIVE_FILE" 2>/dev/null)" == "$safe" ]]; then
        rm -f "$ACTIVE_FILE"
    fi
}

start_stream() {
    if ! command -v afplay >/dev/null 2>&1; then
        tmux display-message "Speak mode error: afplay not found"
        exit 1
    fi
    if ! command -v edge-tts >/dev/null 2>&1 && ! command -v say >/dev/null 2>&1; then
        tmux display-message "Speak mode error: no TTS engine (pipx install edge-tts)"
        exit 1
    fi

    # Claim the audio channel: stop any one-shot (Ctrl+b p) playback, both on
    # this pane and on whichever pane currently owns the playback slot.
    local other
    other="$(cat "$ACTIVE_FILE" 2>/dev/null)"
    if [[ -n "$other" && "$other" != "$SAFE_PANE_ID" ]]; then
        stop_playback_for_pane "$other"
    fi
    stop_playback_for_pane "$SAFE_PANE_ID"
    echo "$SAFE_PANE_ID" > "$ACTIVE_FILE"

    local spool label
    spool="$(spool_for "$SAFE_PANE_ID")"
    rm -rf "$spool"
    mkdir -p "$spool/chunks" "$spool/audio"
    echo 1 > "$spool/chunks/.next"
    label="$(resolve_label)"
    printf '%s\n' "$label" > "$spool/label"
    log_lifecycle "enable: label='$label' path='$(tmux display-message -pt "$PANE_ID" '#{pane_current_path}' 2>/dev/null)'"

    # Spawn workers and record their PIDs BEFORE announcing the mode in
    # stream.pane. The status script's stale-cleanup treats "stream.pane set
    # but watcher.pid dead/missing" as a crashed mode; announcing first opened
    # a race where a status redraw (triggered by mark_pane itself) cleared
    # stream.pane before watcher.pid existed, and every worker then exited on
    # its first mode check (BUG-022). Workers wait up to ~2s for the mode
    # file, so this order is safe.
    nohup "$SCRIPT_DIR/stream-watcher.sh" "$PANE_ID" "$spool" >/dev/null 2>&1 &
    echo "$!" > "$spool/watcher.pid"
    nohup "$SCRIPT_DIR/stream-synth.sh" "$PANE_ID" "$spool" >/dev/null 2>&1 &
    echo "$!" > "$spool/synth.pid"
    nohup "$SCRIPT_DIR/stream-player.sh" "$PANE_ID" "$spool" >/dev/null 2>&1 &
    echo "$!" > "$spool/player.pid"

    echo "$SAFE_PANE_ID" > "$STREAM_PANE_FILE"
    mark_pane "$PANE_ID"
}

acquire_toggle_lock

owner="$(cat "$STREAM_PANE_FILE" 2>/dev/null)"
if [[ "$owner" == "$SAFE_PANE_ID" ]]; then
    log_lifecycle "disable by user"
    stop_stream_for_pane "$SAFE_PANE_ID"
    tmux refresh-client -S 2>/dev/null || true
    tmux display-message "Speak mode OFF"
elif [[ -n "$owner" ]]; then
    log_lifecycle "move from %$owner"
    stop_stream_for_pane "$owner"
    start_stream
    tmux refresh-client -S 2>/dev/null || true
    tmux display-message "Speak mode moved from %$owner to %$SAFE_PANE_ID (Ctrl+b o to stop)"
else
    start_stream
    tmux refresh-client -S 2>/dev/null || true
    tmux display-message "Speak mode ON for %$SAFE_PANE_ID (Ctrl+b o to stop)"
fi
