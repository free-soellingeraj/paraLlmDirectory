#!/usr/bin/env bash
# tmux-repl-selector.sh - choose/switch the AI REPL for an existing env pane.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/para-llm-config.sh"

TARGET_PANE="${1:-}"
TARGET_PATH="${2:-}"

if [[ -z "$TARGET_PANE" ]]; then
    TARGET_PANE="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
fi
if [[ -z "$TARGET_PATH" ]]; then
    TARGET_PATH="$(tmux display-message -p -t "$TARGET_PANE" '#{pane_current_path}' 2>/dev/null)"
fi

if [[ -z "$TARGET_PANE" || -z "$TARGET_PATH" ]]; then
    tmux display-message "REPL selector: unable to determine target pane"
    exit 1
fi

ENV_DIR="$(para_llm_env_dir_for_path "$TARGET_PATH" 2>/dev/null || true)"
if [[ -z "$ENV_DIR" ]]; then
    tmux display-message "REPL selector: active pane is not under $ENVS_DIR"
    exit 1
fi

para_llm_ensure_meta_for_path "$TARGET_PATH" >/dev/null 2>&1 || true
META_DIR="$ENV_DIR/.para-llm"
TRANSCRIPT_FILE="$META_DIR/transcript.log"
HANDOFF_FILE="$META_DIR/handoff.md"
CURRENT_REPL="$(para_llm_repl_for_path "$TARGET_PATH")"

choose_repl() {
    if command -v fzf >/dev/null 2>&1; then
        printf "Claude Code\nCodex\n" | fzf --prompt="REPL for $(basename "$ENV_DIR") [$CURRENT_REPL]> "
    else
        echo "Select REPL:"
        echo "1) Claude Code"
        echo "2) Codex"
        read -r -p "Choice [1]: " choice
        case "$choice" in
            2) echo "Codex" ;;
            *) echo "Claude Code" ;;
        esac
    fi
}

strip_control_sequences() {
    perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\r//g' 2>/dev/null || cat
}

capture_transcript() {
    mkdir -p "$META_DIR"
    {
        echo ""
        echo "===== capture $(date -u +"%Y-%m-%dT%H:%M:%SZ") from $TARGET_PANE ====="
        tmux capture-pane -t "$TARGET_PANE" -p -S - 2>/dev/null
    } >> "$TRANSCRIPT_FILE"
}

write_handoff() {
    local from_repl="$1"
    local to_repl="$2"
    local clean_tail

    clean_tail="$(tail -n 260 "$TRANSCRIPT_FILE" 2>/dev/null | strip_control_sequences | sed '/^[[:space:]]*$/d' | tail -n 180)"

    {
        echo "# para-llm handoff"
        echo ""
        echo "- From: $from_repl"
        echo "- To: $to_repl"
        echo "- Environment: $ENV_DIR"
        echo "- Working directory: $TARGET_PATH"
        echo "- Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo ""
        echo "## Git Status"
        echo '```'
        git -C "$TARGET_PATH" status --short --branch 2>/dev/null || true
        echo '```'
        echo ""
        echo "## Recent Terminal Transcript"
        echo '```'
        printf "%s\n" "$clean_tail"
        echo '```'
        echo ""
        echo "Continue the work from this context. Inspect the repository directly when details are unclear."
    } > "$HANDOFF_FILE"
}

start_transcript_pipe() {
    local quoted_transcript
    quoted_transcript="$(para_llm_shell_quote "$TRANSCRIPT_FILE")"
    tmux pipe-pane -t "$TARGET_PANE" -o "cat >> $quoted_transcript" 2>/dev/null || true
}

selection="$(choose_repl || true)"
case "$selection" in
    "Claude Code") SELECTED_REPL="claude" ;;
    "Codex") SELECTED_REPL="codex" ;;
    *) exit 0 ;;
esac

capture_transcript
para_llm_set_repl_for_path "$TARGET_PATH" "$SELECTED_REPL"
start_transcript_pipe

HANDOFF_PROMPT=""
if [[ "$CURRENT_REPL" != "$SELECTED_REPL" ]]; then
    write_handoff "$CURRENT_REPL" "$SELECTED_REPL"
    HANDOFF_PROMPT="Read .para-llm/handoff.md and continue the work. Use the repository and tools directly to verify the current state."
fi

if [[ -n "$HANDOFF_PROMPT" ]]; then
    LAUNCH_CMD="$(para_llm_repl_command "$SELECTED_REPL" false "$HANDOFF_PROMPT")"
else
    LAUNCH_CMD="$(para_llm_repl_command "$SELECTED_REPL" true)"
fi

tmux respawn-pane -k -t "$TARGET_PANE" -c "$TARGET_PATH" "$LAUNCH_CMD"
tmux display-message "REPL: switched $(basename "$ENV_DIR") to $SELECTED_REPL"
