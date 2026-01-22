#!/bin/bash
# para-llm-config.sh - Configuration loader for para-llm-directory
# Source this file to get CODE_DIR and ENVS_DIR variables

PARA_LLM_CONFIG="$HOME/.para-llm/config"

# Default values (used if no config exists)
DEFAULT_CODE_DIR="$HOME/code"
DEFAULT_ENVS_DIR="$HOME/code/envs"

# Load config if it exists
if [[ -f "$PARA_LLM_CONFIG" ]]; then
    source "$PARA_LLM_CONFIG"
fi

# Use defaults if not set
CODE_DIR="${CODE_DIR:-$DEFAULT_CODE_DIR}"
ENVS_DIR="${ENVS_DIR:-$DEFAULT_ENVS_DIR}"

# Export for child processes
export CODE_DIR
export ENVS_DIR
