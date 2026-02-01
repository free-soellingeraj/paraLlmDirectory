#!/usr/bin/env bash

# Claude Code tmux Status Line Integration
# Shows aggregate Claude state across all active sessions
#
# Usage: tmux-status.sh
# Output: "Claude: 2 ready, 1 working" or "Claude: idle" if no sessions
#
# Add to tmux.conf:
#   set -g status-right '#(/path/to/tmux-status.sh)'
#
# Configuration (in $PARA_LLM_ROOT/config):
#   STATUS_LINE_ENABLED=1|0 (default: 1)
#   STATUS_LINE_PREFIX="Claude" (default: "Claude")
#   STATUS_LINE_EMOJI=1|0 (default: 0, use emoji icons)

set -u

# Load para-llm-directory config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
fi

# Configuration with defaults (config file values take precedence)
STATUS_ENABLED="${STATUS_LINE_ENABLED:-1}"
STATUS_PREFIX="${STATUS_LINE_PREFIX:-Claude}"
USE_EMOJI="${STATUS_LINE_EMOJI:-0}"

# Exit early if disabled
if [[ "$STATUS_ENABLED" != "1" ]]; then
    exit 0
fi

# Find state directory
STATE_DIR="/tmp/claude-state/by-cwd"

# Count states
READY=0
WORKING=0
BLOCKED=0
TOTAL=0

if [[ -d "$STATE_DIR" ]]; then
    for state_file in "$STATE_DIR"/*.json; do
        [[ -f "$state_file" ]] || continue

        STATE=$(jq -r '.state // "unknown"' "$state_file" 2>/dev/null)

        case "$STATE" in
            ready|ended)
                ((READY++))
                ((TOTAL++))
                ;;
            working|starting)
                ((WORKING++))
                ((TOTAL++))
                ;;
            blocked)
                ((BLOCKED++))
                ((TOTAL++))
                ;;
        esac
    done
fi

# Build output string
if [[ "$TOTAL" -eq 0 ]]; then
    # No active sessions
    if [[ "$USE_EMOJI" == "1" ]]; then
        echo "#[fg=colour245]🤖 idle#[default]"
    else
        echo "#[fg=colour245]$STATUS_PREFIX: idle#[default]"
    fi
    exit 0
fi

# Build parts array
PARTS=()

if [[ "$READY" -gt 0 ]]; then
    if [[ "$USE_EMOJI" == "1" ]]; then
        PARTS+=("#[fg=green]✓$READY#[default]")
    else
        PARTS+=("#[fg=green]$READY ready#[default]")
    fi
fi

if [[ "$WORKING" -gt 0 ]]; then
    if [[ "$USE_EMOJI" == "1" ]]; then
        PARTS+=("#[fg=yellow]⚙$WORKING#[default]")
    else
        PARTS+=("#[fg=yellow]$WORKING working#[default]")
    fi
fi

if [[ "$BLOCKED" -gt 0 ]]; then
    if [[ "$USE_EMOJI" == "1" ]]; then
        PARTS+=("#[fg=cyan]⏸$BLOCKED#[default]")
    else
        PARTS+=("#[fg=cyan]$BLOCKED blocked#[default]")
    fi
fi

# Join parts
if [[ "$USE_EMOJI" == "1" ]]; then
    OUTPUT="🤖 "
else
    OUTPUT="$STATUS_PREFIX: "
fi

for i in "${!PARTS[@]}"; do
    if [[ "$i" -gt 0 ]]; then
        OUTPUT+=", "
    fi
    OUTPUT+="${PARTS[$i]}"
done

echo "$OUTPUT"
