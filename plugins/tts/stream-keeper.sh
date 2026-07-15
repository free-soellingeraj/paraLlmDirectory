#!/usr/bin/env bash
# stream-keeper.sh - speak mode's supervisor: the mode only ends when the user
# explicitly toggles it off. Any other death (pane renumbered by a restore,
# worker crash, stale-cleanup, stray teardown) is healed within ~10s.
#
# The binding intent lives in /tmp/para-llm-tts/keepalive (safe pane id +
# pane path), written by toggle-stream on every enable/move and removed ONLY
# by the explicit user disable. While the marker exists this loop revives the
# mode: same pane if it still exists, else the pane now living at the same
# path (env), else retry. Revivals skip the recap (TTS_STREAM_NO_FRAMING).
#
# Singleton: keeper.pid in TTS_DIR. Spawned by toggle-stream.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TTS_DIR="/tmp/para-llm-tts"
KEEP="$TTS_DIR/keepalive"
PIDF="$TTS_DIR/keeper.pid"
STREAM_PANE_FILE="$TTS_DIR/stream.pane"

log_keeper() {
    printf '%s  keeper  %s\n' "$(date '+%F %T')" "$*" >> "$TTS_DIR/stream.log" 2>/dev/null || true
}

# Singleton: bail if another keeper is alive.
other="$(cat "$PIDF" 2>/dev/null)"
if [[ -n "$other" && "$other" != "$$" ]] && kill -0 "$other" 2>/dev/null; then
    exit 0
fi
echo "$$" > "$PIDF"
log_keeper "started"

fails=0
while [[ -f "$KEEP" ]]; do
    safe="$(sed -n 1p "$KEEP" 2>/dev/null)"
    want_path="$(sed -n 2p "$KEEP" 2>/dev/null)"
    if [[ -z "$safe" ]]; then
        sleep 10
        continue
    fi

    cur="$(cat "$STREAM_PANE_FILE" 2>/dev/null)"
    wpid="$(cat "$TTS_DIR/$safe.stream/watcher.pid" 2>/dev/null)"
    if [[ "$cur" == "$safe" && -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
        fails=0
        sleep 10
        continue
    fi

    # Unhealthy. Find where the mode should live now: the same pane if it
    # still exists, else the pane whose cwd is the recorded path (a restore
    # renumbers panes but the env survives).
    panes="$(tmux list-panes -a -F '#{pane_id} #{pane_current_path}' 2>/dev/null)"
    target=""
    while IFS=' ' read -r pid ppath; do
        if [[ "$pid" == "%$safe" ]]; then
            target="$pid"
            break
        fi
    done <<< "$panes"
    if [[ -z "$target" && -n "$want_path" ]]; then
        while IFS=' ' read -r pid ppath; do
            if [[ "$ppath" == "$want_path" ]]; then
                target="$pid"
                break
            fi
        done <<< "$panes"
    fi

    if [[ -n "$target" ]]; then
        # A stale stream.pane matching the target would make toggle-stream
        # read the press as "turn off" — clear it so it starts fresh.
        if [[ -n "$cur" ]]; then
            : > "$STREAM_PANE_FILE"
        fi
        log_keeper "reviving speak mode on $target (was %$safe)"
        TTS_STREAM_NO_FRAMING=1 bash "$SCRIPT_DIR/toggle-stream.sh" "$target" >/dev/null 2>&1 || true
        fails=0
    else
        fails=$((fails + 1))
        if (( fails % 6 == 1 )); then
            log_keeper "cannot revive: pane %$safe gone and no pane at '$want_path' (attempt $fails)"
        fi
        if (( fails > 30 )); then
            log_keeper "giving up after $fails attempts; removing keepalive"
            rm -f "$KEEP"
            break
        fi
    fi
    sleep 10
done

log_keeper "exiting (keepalive removed)"
rm -f "$PIDF"
