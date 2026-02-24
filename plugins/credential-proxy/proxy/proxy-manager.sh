#!/usr/bin/env bash
set -euo pipefail

# Proxy Manager - Start/stop/status for the MITM credential proxy
# Usage: proxy-manager.sh start --env-dir <dir> [--project <name>] [--branch <name>]
#        proxy-manager.sh stop  --env-dir <dir>
#        proxy-manager.sh status --env-dir <dir>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load para-llm config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    PARA_LLM_CONFIG="$PARA_LLM_ROOT/config"
    if [[ -f "$PARA_LLM_CONFIG" ]]; then
        source "$PARA_LLM_CONFIG"
    fi
fi

ACTION="${1:?Usage: proxy-manager.sh <start|stop|status> --env-dir <dir>}"
shift

# Parse arguments
ENV_DIR=""
PROJECT=""
BRANCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-dir) ENV_DIR="$2"; shift 2 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ENV_DIR" ]]; then
    echo "Error: --env-dir is required" >&2
    exit 1
fi

PID_FILE="$ENV_DIR/.credential-proxy.pid"
PORT_FILE="$ENV_DIR/.credential-proxy.port"
PORT_BASE="${CRED_PROXY_PORT_BASE:-18080}"

# Resolve the CA directory
CA_DIR="${PARA_LLM_ROOT:-$HOME/.para-llm}/plugins/credential-proxy/proxy/ca"

# Resolve the rules file (project-level > global)
resolve_rules_file() {
    local project_rules=""
    if [[ -n "$PROJECT" ]] && [[ -d "$ENV_DIR/$PROJECT" ]]; then
        project_rules="$ENV_DIR/$PROJECT/.para-llm/credentials.yaml"
    fi

    if [[ -n "$project_rules" ]] && [[ -f "$project_rules" ]]; then
        echo "$project_rules"
    elif [[ -f "${PARA_LLM_ROOT:-}/plugins/credential-proxy/credentials.yaml" ]]; then
        echo "${PARA_LLM_ROOT}/plugins/credential-proxy/credentials.yaml"
    else
        echo ""
    fi
}

# Find an available port starting from PORT_BASE
find_available_port() {
    local port=$PORT_BASE
    local max_port=$((PORT_BASE + 100))

    while [[ $port -lt $max_port ]]; do
        if ! lsof -i ":$port" &>/dev/null; then
            echo "$port"
            return 0
        fi
        ((port++))
    done

    echo "Error: No available port in range $PORT_BASE-$max_port" >&2
    return 1
}

# Check if proxy is already running
is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        # Stale PID file
        rm -f "$PID_FILE" "$PORT_FILE"
    fi
    return 1
}

start_proxy() {
    # Idempotent: if already running, just report the port
    if is_running; then
        cat "$PORT_FILE"
        return 0
    fi

    # Check for mitmdump
    if ! command -v mitmdump &>/dev/null; then
        echo "Error: mitmdump not found. Install mitmproxy: brew install mitmproxy" >&2
        exit 1
    fi

    local rules_file
    rules_file=$(resolve_rules_file)

    local port
    port=$(find_available_port) || exit 1

    # Build mitmdump command
    local cmd=(
        mitmdump
        --listen-port "$port"
        --set "confdir=$CA_DIR"
        -s "$SCRIPT_DIR/credential-inject.py"
    )

    if [[ -n "$rules_file" ]]; then
        cmd+=(--set "rules_file=$rules_file")
    fi

    cmd+=(--set "providers_dir=$PLUGIN_DIR/providers")

    # Allow connections to upstream servers with invalid certs (optional)
    # cmd+=(--ssl-insecure)

    # Quiet mode - only log errors
    cmd+=(--quiet)

    # Start proxy in background
    "${cmd[@]}" &>/dev/null &
    local proxy_pid=$!

    # Wait briefly to check it started
    sleep 0.5
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
        echo "Error: Proxy failed to start" >&2
        exit 1
    fi

    # Save state
    echo "$proxy_pid" > "$PID_FILE"
    echo "$port" > "$PORT_FILE"

    # Output the port (used by callers)
    echo "$port"
}

stop_proxy() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            # Wait up to 3 seconds for graceful shutdown
            local waited=0
            while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 30 ]]; do
                sleep 0.1
                ((waited++))
            done
            # Force kill if still alive
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE" "$PORT_FILE"
        echo "Proxy stopped"
    else
        echo "No proxy running for this environment"
    fi
}

proxy_status() {
    if is_running; then
        local port
        port=$(cat "$PORT_FILE")
        echo "running:$port"
    else
        echo "stopped"
    fi
}

case "$ACTION" in
    start)
        start_proxy
        ;;
    stop)
        stop_proxy
        ;;
    status)
        proxy_status
        ;;
    *)
        echo "Unknown action: $ACTION" >&2
        echo "Usage: proxy-manager.sh <start|stop|status> --env-dir <dir>" >&2
        exit 1
        ;;
esac
