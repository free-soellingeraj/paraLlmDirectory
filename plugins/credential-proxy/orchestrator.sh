#!/usr/bin/env bash
set -euo pipefail

# Credential Orchestrator - Unified control for all credential services
# Usage: orchestrator.sh <start|stop|status|inject-claude-md|health> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load para-llm config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    PARA_LLM_CONFIG="$PARA_LLM_ROOT/config"
    if [[ -f "$PARA_LLM_CONFIG" ]]; then
        source "$PARA_LLM_CONFIG"
    fi
fi

CONFIG_FILE="${PARA_LLM_ROOT:-}/plugins/credential-proxy/credentials.yaml"
CA_DIR="${PARA_LLM_ROOT:-}/plugins/credential-proxy/proxy/ca"
CA_CERT="$CA_DIR/para-llm-ca.pem"

ACTION="${1:?Usage: orchestrator.sh <start|stop|status|inject-claude-md|health>}"
shift

case "$ACTION" in
    start)
        # Start all credential services for an environment
        # Arguments: --env-dir <dir> --project <name> --branch <name>
        ENV_DIR=""
        PROJECT=""
        BRANCH=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --env-dir) ENV_DIR="$2"; shift 2 ;;
                --project) PROJECT="$2"; shift 2 ;;
                --branch) BRANCH="$2"; shift 2 ;;
                *) shift ;;
            esac
        done

        if [[ -z "$ENV_DIR" ]]; then
            echo "Error: --env-dir is required" >&2
            exit 1
        fi

        # 1. Verify OAuth tokens (non-blocking warning)
        "$SCRIPT_DIR/oauth/verify-oauth.sh" --quiet 2>/dev/null || \
            echo "Warning: Some OAuth tokens may need refresh" >&2

        # 2. Start HTTP proxy (if enabled in config)
        PROXY_ENABLED="true"
        if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
            PROXY_ENABLED=$(yq '.http_proxy.enabled // true' "$CONFIG_FILE" 2>/dev/null)
        fi

        PROXY_PORT=""
        if [[ "$PROXY_ENABLED" == "true" ]]; then
            PROXY_PORT=$("$SCRIPT_DIR/proxy/proxy-manager.sh" start \
                --env-dir "$ENV_DIR" \
                ${PROJECT:+--project "$PROJECT"} \
                ${BRANCH:+--branch "$BRANCH"}) || {
                echo "Warning: HTTP proxy failed to start" >&2
                PROXY_PORT=""
            }
        fi

        # 3. Output environment setup commands (to be eval'd or sent to pane)
        if [[ -n "$PROXY_PORT" ]]; then
            echo "export HTTP_PROXY=http://127.0.0.1:$PROXY_PORT"
            echo "export HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT"

            if [[ -f "$CA_CERT" ]]; then
                echo "export NODE_EXTRA_CA_CERTS=\"$CA_CERT\""
                echo "export REQUESTS_CA_BUNDLE=\"$CA_CERT\""
                echo "export SSL_CERT_FILE=\"$CA_CERT\""
                echo "export GIT_SSL_CAINFO=\"$CA_CERT\""
            fi
        fi
        ;;

    stop)
        # Stop all credential services for an environment
        ENV_DIR=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --env-dir) ENV_DIR="$2"; shift 2 ;;
                *) shift ;;
            esac
        done

        if [[ -z "$ENV_DIR" ]]; then
            echo "Error: --env-dir is required" >&2
            exit 1
        fi

        # Stop HTTP proxy
        "$SCRIPT_DIR/proxy/proxy-manager.sh" stop --env-dir "$ENV_DIR" 2>/dev/null || true
        ;;

    status)
        # Check status of all credential services
        ENV_DIR=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --env-dir) ENV_DIR="$2"; shift 2 ;;
                *) shift ;;
            esac
        done

        echo "Credential Orchestrator Status"
        echo "=============================="

        # OAuth status
        echo ""
        echo "OAuth:"
        "$SCRIPT_DIR/oauth/verify-oauth.sh" 2>/dev/null || true

        # Proxy status
        if [[ -n "$ENV_DIR" ]]; then
            echo ""
            echo "HTTP Proxy:"
            STATUS=$("$SCRIPT_DIR/proxy/proxy-manager.sh" status --env-dir "$ENV_DIR" 2>/dev/null || echo "unknown")
            echo "  $STATUS"
        fi

        # Provider health
        echo ""
        echo "Providers:"
        for provider in "$SCRIPT_DIR/providers/"*.sh; do
            PNAME=$(basename "$provider" .sh)
            if HEALTH=$("$provider" health 2>/dev/null); then
                echo "  $PNAME: $HEALTH"
            else
                echo "  $PNAME: FAILED"
            fi
        done
        ;;

    inject-claude-md)
        # Inject credential proxy awareness into a project's CLAUDE.md
        PROJECT_DIR="${1:?Usage: orchestrator.sh inject-claude-md <project-dir>}"

        CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"
        SNIPPET_FILE="$SCRIPT_DIR/config/claude-md-snippet.md"
        MARKER="## Authenticated Services (Credential Proxy)"

        if [[ ! -f "$SNIPPET_FILE" ]]; then
            echo "Snippet file not found: $SNIPPET_FILE" >&2
            exit 1
        fi

        if [[ -f "$CLAUDE_MD" ]]; then
            # Check if already injected
            if grep -qF "$MARKER" "$CLAUDE_MD"; then
                # Already present
                exit 0
            fi
            # Append to existing CLAUDE.md
            echo "" >> "$CLAUDE_MD"
            cat "$SNIPPET_FILE" >> "$CLAUDE_MD"
        else
            # Create new CLAUDE.md with snippet
            cat "$SNIPPET_FILE" > "$CLAUDE_MD"
        fi

        echo "Injected credential proxy context into $CLAUDE_MD"
        ;;

    health)
        # Quick health check of all providers
        ALL_OK=true
        for provider in "$SCRIPT_DIR/providers/"*.sh; do
            PNAME=$(basename "$provider" .sh)
            if ! "$provider" health &>/dev/null; then
                echo "$PNAME: FAILED" >&2
                ALL_OK=false
            fi
        done

        if [[ "$ALL_OK" == true ]]; then
            echo "ok"
        else
            exit 1
        fi
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        echo "Usage: orchestrator.sh <start|stop|status|inject-claude-md|health>" >&2
        exit 1
        ;;
esac
