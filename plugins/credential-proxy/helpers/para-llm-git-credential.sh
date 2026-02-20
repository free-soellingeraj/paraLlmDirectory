#!/usr/bin/env bash
set -euo pipefail

# Git credential helper for para-llm-directory
# Called by git as: git credential-para-llm <action>
# Fetches tokens from the configured provider backend.
#
# Install: git config --global credential.helper "/path/to/para-llm-git-credential.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROVIDERS_DIR="$PLUGIN_DIR/providers"

# Load para-llm config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
fi

CONFIG_FILE="${PARA_LLM_ROOT:-}/plugins/credential-proxy/credentials.yaml"

ACTION="${1:-}"

# Only handle 'get' requests
if [[ "$ACTION" != "get" ]]; then
    exit 0
fi

# Parse git's credential input from stdin
PROTOCOL=""
HOST=""
while IFS='=' read -r key value; do
    [[ -z "$key" ]] && break
    case "$key" in
        protocol) PROTOCOL="$value" ;;
        host)     HOST="$value" ;;
    esac
done

if [[ -z "$HOST" ]]; then
    exit 0
fi

# Read config to find provider and secret_ref for git
if [[ ! -f "$CONFIG_FILE" ]]; then
    exit 0
fi

# Use yq if available, otherwise fall back to grep-based parsing
if command -v yq &>/dev/null; then
    ENABLED=$(yq '.credential_helpers.git.enabled // false' "$CONFIG_FILE" 2>/dev/null)
    if [[ "$ENABLED" != "true" ]]; then
        exit 0
    fi

    PROVIDER=$(yq '.credential_helpers.git.provider // "gcp-secrets"' "$CONFIG_FILE" 2>/dev/null)
    SECRET_REF=$(yq '.credential_helpers.git.secret_ref // ""' "$CONFIG_FILE" 2>/dev/null)
else
    # Basic fallback: check if git credential helper is configured
    # This won't handle complex YAML but works for simple cases
    exit 0
fi

if [[ -z "$SECRET_REF" ]]; then
    exit 0
fi

# Resolve provider config
PROVIDER_ARGS=()
if command -v yq &>/dev/null; then
    GCP_PROJECT=$(yq ".providers.${PROVIDER}.project // \"\"" "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$GCP_PROJECT" ]]; then
        PROVIDER_ARGS+=("project=$GCP_PROJECT")
    fi
fi

# Fetch the token from the provider
PROVIDER_SCRIPT="$PROVIDERS_DIR/${PROVIDER}.sh"
if [[ ! -x "$PROVIDER_SCRIPT" ]]; then
    echo "Provider script not found or not executable: $PROVIDER_SCRIPT" >&2
    exit 1
fi

TOKEN=$("$PROVIDER_SCRIPT" get "$SECRET_REF" "${PROVIDER_ARGS[@]}" 2>/dev/null) || {
    echo "Failed to fetch credential from provider $PROVIDER" >&2
    exit 1
}

# Output in git credential helper format
echo "protocol=${PROTOCOL:-https}"
echo "host=$HOST"
echo "username=x-token"
echo "password=$TOKEN"
