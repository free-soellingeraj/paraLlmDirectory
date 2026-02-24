#!/usr/bin/env bash
set -euo pipefail

# Install and configure credential helpers for git, docker, npm
# Usage: setup-helpers.sh [--git] [--docker] [--all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load para-llm config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
fi

SETUP_GIT=false
SETUP_DOCKER=false

# Parse arguments
if [[ $# -eq 0 ]] || [[ "$1" == "--all" ]]; then
    SETUP_GIT=true
    SETUP_DOCKER=true
else
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --git) SETUP_GIT=true; shift ;;
            --docker) SETUP_DOCKER=true; shift ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done
fi

# --- Git credential helper ---
if [[ "$SETUP_GIT" == true ]]; then
    echo "Setting up git credential helper..."

    GIT_HELPER="$SCRIPT_DIR/para-llm-git-credential.sh"
    chmod +x "$GIT_HELPER"

    # Configure git to use our credential helper
    git config --global credential.helper "$GIT_HELPER"

    echo "  Configured: git config --global credential.helper"
    echo "  Helper: $GIT_HELPER"
    echo ""
fi

# --- Docker credential helper ---
if [[ "$SETUP_DOCKER" == true ]]; then
    echo "Setting up docker credential helper..."

    DOCKER_HELPER="$SCRIPT_DIR/docker-credential-para-llm.sh"
    chmod +x "$DOCKER_HELPER"

    # Docker expects the helper to be on PATH as "docker-credential-<name>"
    # Create a symlink in a directory that's on PATH
    LOCAL_BIN="$HOME/.local/bin"
    mkdir -p "$LOCAL_BIN"

    SYMLINK_PATH="$LOCAL_BIN/docker-credential-para-llm"
    ln -sf "$DOCKER_HELPER" "$SYMLINK_PATH"

    # Check if ~/.local/bin is on PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$LOCAL_BIN"; then
        echo "  Warning: $LOCAL_BIN is not on your PATH."
        echo "  Add this to your shell profile:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi

    # Update docker config.json if yq is available
    DOCKER_CONFIG_DIR="$HOME/.docker"
    DOCKER_CONFIG="$DOCKER_CONFIG_DIR/config.json"

    if [[ -f "$DOCKER_CONFIG" ]]; then
        echo "  Docker config exists at $DOCKER_CONFIG"
        echo "  To add registries, edit the 'credHelpers' section:"
        echo '    { "credHelpers": { "ghcr.io": "para-llm" } }'
    else
        echo "  No docker config found. Creating minimal config..."
        mkdir -p "$DOCKER_CONFIG_DIR"
        echo '{ "credHelpers": {} }' > "$DOCKER_CONFIG"
        echo "  Created $DOCKER_CONFIG"
        echo "  Add registries to the 'credHelpers' section as needed."
    fi

    echo "  Helper: $DOCKER_HELPER"
    echo "  Symlink: $SYMLINK_PATH"
    echo ""
fi

echo "Credential helper setup complete."
