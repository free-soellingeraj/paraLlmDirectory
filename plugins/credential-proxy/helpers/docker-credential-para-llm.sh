#!/usr/bin/env bash
set -euo pipefail

# Docker credential helper for para-llm-directory
# Follows the Docker credential helper protocol:
#   https://docs.docker.com/engine/reference/commandline/login/#credential-helpers
#
# Actions:
#   get   - Read registry URL from stdin, output {"Username":"x","Secret":"<token>"}
#   store - No-op (secrets managed by provider backend)
#   erase - No-op (secrets managed by provider backend)
#   list  - List configured registries
#
# Install: Add to ~/.docker/config.json:
#   { "credHelpers": { "ghcr.io": "para-llm" } }
#
# The script must be named "docker-credential-para-llm" and be on PATH.

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

case "$ACTION" in
    get)
        # Read registry URL from stdin
        REGISTRY=$(cat)
        # Strip protocol prefix if present
        REGISTRY="${REGISTRY#https://}"
        REGISTRY="${REGISTRY#http://}"
        # Strip trailing slash
        REGISTRY="${REGISTRY%/}"

        if [[ -z "$REGISTRY" ]] || [[ ! -f "$CONFIG_FILE" ]]; then
            echo '{"Username":"","Secret":""}' >&2
            exit 1
        fi

        if ! command -v yq &>/dev/null; then
            echo "yq not found — cannot parse config" >&2
            exit 1
        fi

        # Check if docker credential helpers are enabled
        ENABLED=$(yq '.credential_helpers.docker.enabled // false' "$CONFIG_FILE" 2>/dev/null)
        if [[ "$ENABLED" != "true" ]]; then
            exit 1
        fi

        # Look up this registry in the config
        PROVIDER=$(yq ".credential_helpers.docker.registries.\"${REGISTRY}\".provider // \"\"" "$CONFIG_FILE" 2>/dev/null)
        SECRET_REF=$(yq ".credential_helpers.docker.registries.\"${REGISTRY}\".secret_ref // \"\"" "$CONFIG_FILE" 2>/dev/null)

        if [[ -z "$PROVIDER" ]] || [[ -z "$SECRET_REF" ]]; then
            echo "Registry '$REGISTRY' not configured in credentials.yaml" >&2
            exit 1
        fi

        # Resolve provider config
        PROVIDER_ARGS=()
        GCP_PROJECT=$(yq ".providers.${PROVIDER}.project // \"\"" "$CONFIG_FILE" 2>/dev/null)
        if [[ -n "$GCP_PROJECT" ]]; then
            PROVIDER_ARGS+=("project=$GCP_PROJECT")
        fi

        # Fetch the token
        PROVIDER_SCRIPT="$PROVIDERS_DIR/${PROVIDER}.sh"
        if [[ ! -x "$PROVIDER_SCRIPT" ]]; then
            echo "Provider script not found: $PROVIDER_SCRIPT" >&2
            exit 1
        fi

        TOKEN=$("$PROVIDER_SCRIPT" get "$SECRET_REF" "${PROVIDER_ARGS[@]}" 2>/dev/null) || {
            echo "Failed to fetch credential for registry $REGISTRY" >&2
            exit 1
        }

        # Output in Docker credential helper format
        printf '{"Username":"_token","Secret":"%s"}' "$TOKEN"
        ;;

    store)
        # No-op: secrets are managed by the provider backend
        cat > /dev/null
        ;;

    erase)
        # No-op: secrets are managed by the provider backend
        cat > /dev/null
        ;;

    list)
        # List configured registries
        if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
            yq '.credential_helpers.docker.registries | keys | .[]' "$CONFIG_FILE" 2>/dev/null | \
                while read -r reg; do
                    printf '"%s":"_token"\n' "$reg"
                done | paste -sd, | sed 's/^/{/;s/$/}/'
        else
            echo '{}'
        fi
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
