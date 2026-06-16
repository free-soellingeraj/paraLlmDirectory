#!/usr/bin/env bash
# voice-script.sh - record a speakable script for the current tmux pane so that
# Ctrl+b p (toggle-tts.sh) plays it directly, with NO capture + LLM summarize
# step. Meant to be called by the coding agent running inside the pane (via the
# para-voice-script skill / codex prompt): the agent already has full context of
# what it just did, so it can write a better briefing than re-summarizing
# scrollback after the fact.
#
# Usage:
#   voice-script.sh "speakable prose..."     # text from arguments
#   some-command | voice-script.sh           # text from stdin
#   voice-script.sh --clear                  # drop the authored script (revert to live capture)
#   voice-script.sh --show                   # print the current authored script, if any

set -uo pipefail

TTS_DIR="/tmp/para-llm-tts"
mkdir -p "$TTS_DIR"

# Resolve the pane this command is running in. tmux exports $TMUX_PANE in every
# pane; fall back to querying tmux directly.
PANE_ID="${TMUX_PANE:-}"
if [[ -z "$PANE_ID" ]]; then
    PANE_ID="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi
if [[ -z "$PANE_ID" ]]; then
    echo "voice-script: not inside a tmux pane (no \$TMUX_PANE); cannot target playback" >&2
    exit 1
fi
SAFE_PANE_ID="${PANE_ID#%}"
AUTHORED_FILE="$TTS_DIR/$SAFE_PANE_ID.authored.txt"

case "${1:-}" in
    --clear)
        rm -f "$AUTHORED_FILE"
        echo "voice-script: cleared authored script for pane $PANE_ID"
        exit 0
        ;;
    --show)
        if [[ -s "$AUTHORED_FILE" ]]; then
            cat "$AUTHORED_FILE"
        else
            echo "voice-script: no authored script for pane $PANE_ID" >&2
            exit 1
        fi
        exit 0
        ;;
esac

# Text comes from arguments if given, otherwise from stdin.
if [[ $# -gt 0 ]]; then
    printf '%s\n' "$*" > "$AUTHORED_FILE"
else
    cat > "$AUTHORED_FILE"
fi

if [[ ! -s "$AUTHORED_FILE" ]]; then
    rm -f "$AUTHORED_FILE"
    echo "voice-script: empty input; nothing recorded" >&2
    exit 1
fi

words="$(wc -w < "$AUTHORED_FILE" | tr -d ' ')"
echo "voice-script: recorded $words words for pane $PANE_ID — press Ctrl+b p to play"
