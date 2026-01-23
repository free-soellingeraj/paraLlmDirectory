#!/bin/bash
# para-llm-config.sh - Configuration loader for para-llm-directory
# Source this file to get PARA_LLM_ROOT, CODE_DIR, and ENVS_DIR variables

BOOTSTRAP_FILE="$HOME/.para-llm-root"

# Default values (used if no bootstrap/config exists)
DEFAULT_CODE_DIR="$HOME/code"
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

# Export for child processes
export PARA_LLM_ROOT
export CODE_DIR
export ENVS_DIR
