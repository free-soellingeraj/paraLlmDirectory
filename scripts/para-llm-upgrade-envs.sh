#!/usr/bin/env bash
# para-llm-upgrade-envs.sh - add para-llm metadata to existing envs/worktrees.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/../para-llm-config.sh" ]]; then
    source "$SCRIPT_DIR/../para-llm-config.sh"
elif [[ -f "$SCRIPT_DIR/para-llm-config.sh" ]]; then
    source "$SCRIPT_DIR/para-llm-config.sh"
else
    BOOTSTRAP_FILE="$HOME/.para-llm-root"
    if [[ -f "$BOOTSTRAP_FILE" ]]; then
        PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
        source "$PARA_LLM_ROOT/config"
        ENVS_DIR="$PARA_LLM_ROOT/envs"
    else
        echo "para-llm: no config found" >&2
        exit 1
    fi
fi

DEFAULT_REPL="${1:-$PARA_LLM_DEFAULT_REPL}"
case "$DEFAULT_REPL" in
    claude|codex) ;;
    *) DEFAULT_REPL="$PARA_LLM_DEFAULT_REPL" ;;
esac

if [[ ! -d "$ENVS_DIR" ]]; then
    echo "No envs directory found at $ENVS_DIR"
    exit 0
fi

upgrade_env() {
    local env_dir="$1"
    local meta_dir="$env_dir/.para-llm"
    local status="upgraded"

    mkdir -p "$meta_dir"
    touch "$meta_dir/transcript.log"

    if [[ -f "$meta_dir/repl" ]]; then
        status="already configured"
    else
        printf "%s\n" "$DEFAULT_REPL" > "$meta_dir/repl"
    fi

    if [[ -f "$env_dir/CLAUDE.md" && ! -f "$env_dir/AGENTS.md" ]]; then
        cp "$env_dir/CLAUDE.md" "$env_dir/AGENTS.md"
    fi

    printf "%s|%s\n" "$status" "$env_dir"
}

attach_transcript_pipe() {
    command -v tmux >/dev/null 2>&1 || return 0
    tmux list-panes -a -F '#{pane_id}|#{pane_current_path}' 2>/dev/null | while IFS='|' read -r pane_id pane_path; do
        case "$pane_path" in
            "$ENVS_DIR"/*)
                local env_dir meta_dir transcript_file quoted_transcript
                env_dir="$(para_llm_env_dir_for_path "$pane_path" 2>/dev/null || true)"
                [[ -n "$env_dir" ]] || continue
                meta_dir="$env_dir/.para-llm"
                mkdir -p "$meta_dir"
                transcript_file="$meta_dir/transcript.log"
                touch "$transcript_file"
                quoted_transcript="$(para_llm_shell_quote "$transcript_file")"
                tmux pipe-pane -t "$pane_id" -o "cat >> $quoted_transcript" 2>/dev/null || true
                ;;
        esac
    done
}

UPGRADED=0
ALREADY=0
while IFS= read -r env_dir; do
    [[ -d "$env_dir" ]] || continue
    result="$(upgrade_env "$env_dir")"
    status="${result%%|*}"
    path="${result#*|}"
    case "$status" in
        "already configured") ALREADY=$((ALREADY + 1)) ;;
        *) UPGRADED=$((UPGRADED + 1)) ;;
    esac
    echo "$status: $path"
done < <(find "$ENVS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

attach_transcript_pipe

echo "Summary: upgraded=$UPGRADED already_configured=$ALREADY"
