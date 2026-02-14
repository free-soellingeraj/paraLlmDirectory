#!/usr/bin/env bash

# STT status for tmux status line
# Shows REC indicator when recording, empty otherwise

PID_FILE="/tmp/claude-stt/recording.pid"

if [[ -f "$PID_FILE" ]]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "#[fg=red,bold]REC#[default]"
    else
        # Stale PID file
        rm -f "$PID_FILE"
    fi
fi
