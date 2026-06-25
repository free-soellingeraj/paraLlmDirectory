#!/usr/bin/env bash
# para-llm-config.sh - Configuration loader for para-llm-directory
# Source this file to get PARA_LLM_ROOT, CODE_DIR, and ENVS_DIR variables

set -u

BOOTSTRAP_FILE="$HOME/.para-llm-root"

# Default values (used if no bootstrap/config exists)
DEFAULT_CODE_DIR="$(pwd)"
DEFAULT_PARA_LLM_ROOT="$DEFAULT_CODE_DIR/.para-llm-directory"

# Read PARA_LLM_ROOT from bootstrap pointer
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
fi
PARA_LLM_ROOT="${PARA_LLM_ROOT:-$DEFAULT_PARA_LLM_ROOT}"

# Load config from PARA_LLM_ROOT if it exists
PARA_LLM_CONFIG="$PARA_LLM_ROOT/config"
if [[ -f "$PARA_LLM_CONFIG" ]]; then
    source "$PARA_LLM_CONFIG"
fi

# Derive ENVS_DIR from PARA_LLM_ROOT
ENVS_DIR="$PARA_LLM_ROOT/envs"

# Use defaults if CODE_DIR not set
CODE_DIR="${CODE_DIR:-$DEFAULT_CODE_DIR}"

# REPL launch profiles. The selected REPL is stored per environment in
# $ENV_DIR/.para-llm/repl; these args only define each product's native defaults.
CLAUDE_LAUNCH_ARGS="${CLAUDE_LAUNCH_ARGS:---permission-mode auto}"
CODEX_LAUNCH_ARGS="${CODEX_LAUNCH_ARGS:---yolo}"
PARA_LLM_DEFAULT_REPL="${PARA_LLM_DEFAULT_REPL:-claude}"

para_llm_shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

para_llm_env_dir_for_path() {
    local path="${1:-$(pwd)}"

    case "$path" in
        "$ENVS_DIR"/*)
            local rel env_name
            rel="${path#"$ENVS_DIR"/}"
            env_name="${rel%%/*}"
            if [[ -n "$env_name" ]]; then
                echo "$ENVS_DIR/$env_name"
                return 0
            fi
            ;;
    esac

    return 1
}

para_llm_meta_dir_for_path() {
    local path="${1:-$(pwd)}"
    local env_dir

    if env_dir="$(para_llm_env_dir_for_path "$path")"; then
        echo "$env_dir/.para-llm"
        return 0
    fi

    return 1
}

para_llm_ensure_meta_for_path() {
    local path="${1:-$(pwd)}"
    local repl="${2:-$PARA_LLM_DEFAULT_REPL}"
    local meta_dir

    if ! meta_dir="$(para_llm_meta_dir_for_path "$path")"; then
        return 1
    fi

    mkdir -p "$meta_dir"
    touch "$meta_dir/transcript.log"
    if [[ ! -f "$meta_dir/repl" ]]; then
        printf "%s\n" "$repl" > "$meta_dir/repl"
    fi
}

para_llm_repl_for_path() {
    local path="${1:-$(pwd)}"
    local meta_dir

    if meta_dir="$(para_llm_meta_dir_for_path "$path")" && [[ -f "$meta_dir/repl" ]]; then
        head -n 1 "$meta_dir/repl"
    else
        echo "$PARA_LLM_DEFAULT_REPL"
    fi
}

para_llm_set_repl_for_path() {
    local path="$1"
    local repl="$2"
    local meta_dir

    case "$repl" in
        claude|codex) ;;
        *) repl="$PARA_LLM_DEFAULT_REPL" ;;
    esac

    meta_dir="$(para_llm_meta_dir_for_path "$path")" || return 1
    mkdir -p "$meta_dir"
    printf "%s\n" "$repl" > "$meta_dir/repl"
    touch "$meta_dir/transcript.log"
}

para_llm_repl_process_pattern() {
    local repl="$1"

    case "$repl" in
        codex) echo "codex" ;;
        claude|*) echo "claude" ;;
    esac
}

para_llm_repl_command() {
    local repl="$1"
    local resume="${2:-false}"
    local handoff_prompt="${3:-}"

    case "$repl" in
        codex)
            if [[ -n "$handoff_prompt" ]]; then
                if [[ -n "$CODEX_LAUNCH_ARGS" ]]; then
                    echo "codex $CODEX_LAUNCH_ARGS $(para_llm_shell_quote "$handoff_prompt")"
                else
                    echo "codex $(para_llm_shell_quote "$handoff_prompt")"
                fi
            elif [[ "$resume" == "true" ]]; then
                if [[ -n "$CODEX_LAUNCH_ARGS" ]]; then
                    echo "codex $CODEX_LAUNCH_ARGS resume --last"
                else
                    echo "codex resume --last"
                fi
            elif [[ -n "$CODEX_LAUNCH_ARGS" ]]; then
                echo "codex $CODEX_LAUNCH_ARGS"
            else
                echo "codex"
            fi
            ;;
        claude|*)
            if [[ -n "$handoff_prompt" ]]; then
                echo "claude $CLAUDE_LAUNCH_ARGS $(para_llm_shell_quote "$handoff_prompt")"
            elif [[ "$resume" == "true" ]]; then
                echo "claude $CLAUDE_LAUNCH_ARGS --resume"
            else
                echo "claude $CLAUDE_LAUNCH_ARGS"
            fi
            ;;
    esac
}

para_llm_repl_command_for_path() {
    local path="$1"
    local resume="${2:-false}"
    local repl

    repl="$(para_llm_repl_for_path "$path")"
    para_llm_repl_command "$repl" "$resume"
}

# Export for child processes
export PARA_LLM_ROOT
export CODE_DIR
export ENVS_DIR
export CLAUDE_LAUNCH_ARGS
export CODEX_LAUNCH_ARGS
export PARA_LLM_DEFAULT_REPL
