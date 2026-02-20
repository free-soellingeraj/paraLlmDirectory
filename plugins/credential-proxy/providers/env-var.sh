#!/usr/bin/env bash
set -euo pipefail

# Environment variable provider (for testing / simple setups)
# Usage: env-var.sh get <secret-ref> [env_name=<VAR_NAME>]
#        env-var.sh health
#
# If env_name is not specified, secret-ref is used as the env var name directly.

ACTION="${1:?Usage: env-var.sh <get|health> <secret-ref> [env_name=<VAR_NAME>]}"

case "$ACTION" in
    get)
        SECRET_REF="${2:?Missing secret reference}"
        shift 2

        # Parse optional config
        ENV_NAME="$SECRET_REF"
        for arg in "$@"; do
            case "$arg" in
                env_name=*) ENV_NAME="${arg#env_name=}" ;;
            esac
        done

        VALUE="${!ENV_NAME:-}"
        if [[ -z "$VALUE" ]]; then
            echo "Environment variable '$ENV_NAME' is not set or empty" >&2
            exit 1
        fi
        printf '%s' "$VALUE"
        ;;

    health)
        echo "ok"
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        exit 1
        ;;
esac
