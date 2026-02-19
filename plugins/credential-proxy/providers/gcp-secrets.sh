#!/usr/bin/env bash
set -euo pipefail

# GCP Secret Manager provider
# Usage: gcp-secrets.sh get <secret-ref> [project=<gcp-project>]
#        gcp-secrets.sh health

ACTION="${1:?Usage: gcp-secrets.sh <get|health> <secret-ref> [project=<gcp-project>]}"

case "$ACTION" in
    get)
        SECRET_REF="${2:?Missing secret reference}"
        shift 2

        # Parse optional config
        GCP_PROJECT=""
        for arg in "$@"; do
            case "$arg" in
                project=*) GCP_PROJECT="${arg#project=}" ;;
            esac
        done

        if [[ -n "$GCP_PROJECT" ]]; then
            gcloud secrets versions access latest \
                --secret="$SECRET_REF" \
                --project="$GCP_PROJECT" 2>/dev/null
        else
            gcloud secrets versions access latest \
                --secret="$SECRET_REF" 2>/dev/null
        fi
        ;;

    health)
        if ! command -v gcloud &>/dev/null; then
            echo "gcloud CLI not installed" >&2
            exit 1
        fi
        gcloud auth print-access-token >/dev/null 2>&1 && echo "ok" || {
            echo "not authenticated - run 'gcloud auth login'" >&2
            exit 1
        }
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        echo "Usage: gcp-secrets.sh <get|health> <secret-ref> [project=<gcp-project>]" >&2
        exit 1
        ;;
esac
