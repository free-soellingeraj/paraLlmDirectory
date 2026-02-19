#!/usr/bin/env bash
set -euo pipefail

# File provider (for testing / simple setups)
# Usage: file.sh get <secret-ref> [dir=<secrets-dir>]
#        file.sh health [dir=<secrets-dir>]
#
# Reads secret from: <dir>/<secret-ref>
# Default dir: $PARA_LLM_ROOT/plugins/credential-proxy/secrets/

ACTION="${1:?Usage: file.sh <get|health> <secret-ref> [dir=<secrets-dir>]}"

DEFAULT_DIR="${PARA_LLM_ROOT:-}/plugins/credential-proxy/secrets"

case "$ACTION" in
    get)
        SECRET_REF="${2:?Missing secret reference}"
        shift 2

        # Parse optional config
        SECRETS_DIR="$DEFAULT_DIR"
        for arg in "$@"; do
            case "$arg" in
                dir=*) SECRETS_DIR="${arg#dir=}" ;;
            esac
        done

        SECRET_FILE="$SECRETS_DIR/$SECRET_REF"
        if [[ ! -f "$SECRET_FILE" ]]; then
            echo "Secret file not found: $SECRET_FILE" >&2
            exit 1
        fi

        cat "$SECRET_FILE"
        ;;

    health)
        shift
        SECRETS_DIR="$DEFAULT_DIR"
        for arg in "$@"; do
            case "$arg" in
                dir=*) SECRETS_DIR="${arg#dir=}" ;;
            esac
        done

        if [[ -d "$SECRETS_DIR" ]]; then
            echo "ok"
        else
            echo "Secrets directory not found: $SECRETS_DIR" >&2
            exit 1
        fi
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
