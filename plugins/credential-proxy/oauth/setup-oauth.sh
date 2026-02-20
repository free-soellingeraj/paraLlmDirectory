#!/usr/bin/env bash
set -euo pipefail

# Set up OAuth / CLI authentication for tools that support it
# Usage: setup-oauth.sh [--gcloud] [--gh] [--az] [--all] [--non-interactive]
#
# This runs interactive OAuth flows for each tool.
# Tokens are stored by each tool's native storage (keychain, config dir, etc.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load para-llm config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
fi

CONFIG_FILE="${PARA_LLM_ROOT:-}/plugins/credential-proxy/credentials.yaml"
NON_INTERACTIVE=false

SETUP_GCLOUD=false
SETUP_GH=false
SETUP_AZ=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --gcloud) SETUP_GCLOUD=true ;;
        --gh) SETUP_GH=true ;;
        --az) SETUP_AZ=true ;;
        --all) SETUP_GCLOUD=true; SETUP_GH=true; SETUP_AZ=true ;;
        --non-interactive) NON_INTERACTIVE=true ;;
    esac
done

# If no specific tool requested, check config
if [[ "$SETUP_GCLOUD" == false ]] && [[ "$SETUP_GH" == false ]] && [[ "$SETUP_AZ" == false ]]; then
    if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
        [[ "$(yq '.oauth.gcloud.enabled // false' "$CONFIG_FILE" 2>/dev/null)" == "true" ]] && SETUP_GCLOUD=true
        [[ "$(yq '.oauth.gh.enabled // false' "$CONFIG_FILE" 2>/dev/null)" == "true" ]] && SETUP_GH=true
        [[ "$(yq '.oauth.az.enabled // false' "$CONFIG_FILE" 2>/dev/null)" == "true" ]] && SETUP_AZ=true
    fi
fi

# --- gcloud ---
if [[ "$SETUP_GCLOUD" == true ]]; then
    echo "=== Google Cloud SDK ==="

    if ! command -v gcloud &>/dev/null; then
        echo "  gcloud not found. Skipping."
        echo "  Install: https://cloud.google.com/sdk/docs/install"
    else
        # Check if already authenticated
        if gcloud auth print-access-token &>/dev/null; then
            ACCOUNT=$(gcloud config get-value account 2>/dev/null)
            echo "  Already authenticated as: $ACCOUNT"
        elif [[ "$NON_INTERACTIVE" == false ]]; then
            echo "  Running 'gcloud auth login'..."
            gcloud auth login
        else
            echo "  Not authenticated. Run 'gcloud auth login' manually."
        fi

        # Check for service account impersonation config
        if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
            SA=$(yq '.oauth.gcloud.service_account // ""' "$CONFIG_FILE" 2>/dev/null)
            if [[ -n "$SA" ]]; then
                echo "  Service account impersonation configured: $SA"
                echo "  Setting default: gcloud config set auth/impersonate_service_account"
                gcloud config set auth/impersonate_service_account "$SA" 2>/dev/null || true
            fi
        fi
    fi
    echo ""
fi

# --- GitHub CLI ---
if [[ "$SETUP_GH" == true ]]; then
    echo "=== GitHub CLI ==="

    if ! command -v gh &>/dev/null; then
        echo "  gh not found. Skipping."
        echo "  Install: brew install gh"
    else
        # Check if already authenticated
        if gh auth status &>/dev/null; then
            echo "  Already authenticated."
            gh auth status 2>&1 | sed 's/^/  /'
        elif [[ "$NON_INTERACTIVE" == false ]]; then
            echo "  Running 'gh auth login'..."
            gh auth login
        else
            echo "  Not authenticated. Run 'gh auth login' manually."
        fi
    fi
    echo ""
fi

# --- Azure CLI ---
if [[ "$SETUP_AZ" == true ]]; then
    echo "=== Azure CLI ==="

    if ! command -v az &>/dev/null; then
        echo "  az not found. Skipping."
        echo "  Install: brew install azure-cli"
    else
        # Check if already authenticated
        if az account show &>/dev/null; then
            echo "  Already authenticated."
            az account show --query '{name:name, user:user.name}' -o table 2>&1 | sed 's/^/  /'
        elif [[ "$NON_INTERACTIVE" == false ]]; then
            echo "  Running 'az login'..."
            az login
        else
            echo "  Not authenticated. Run 'az login' manually."
        fi
    fi
    echo ""
fi

echo "OAuth setup complete."
