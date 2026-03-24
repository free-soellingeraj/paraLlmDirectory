#!/usr/bin/env bash
# openshell-gateway.sh - Gateway lifecycle management
# Ensures the OpenShell gateway is running before sandbox operations

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
fi
PARA_LLM_ROOT="${PARA_LLM_ROOT:-$HOME/.para-llm-directory}"

OPENSHELL_DIR="$PARA_LLM_ROOT/openshell"
GATEWAY_STATE="$OPENSHELL_DIR/state/gateway-status"

# Check if openshell CLI is available
# Returns: 0 if available, 1 if not
openshell_available() {
    if ! command -v openshell &>/dev/null; then
        return 1
    fi
    return 0
}

# Check if Docker is running
# Returns: 0 if running, 1 if not
docker_available() {
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Check gateway health
# Returns: 0 if healthy, 1 if not
gateway_status() {
    if ! openshell_available; then
        echo "not-installed"
        return 1
    fi

    # Use openshell status to check gateway
    local status_output
    if status_output=$(openshell status 2>&1); then
        echo "running"
        return 0
    else
        echo "stopped"
        return 1
    fi
}

# Ensure the gateway is running, start if needed
# Returns: 0 if gateway is running (or started), 1 on failure
# Outputs: status messages to stderr
ensure_gateway() {
    if ! openshell_available; then
        echo "ERROR: openshell CLI not found on PATH" >&2
        echo "Install with: uv tool install -U openshell" >&2
        return 1
    fi

    if ! docker_available; then
        echo "ERROR: Docker is not running" >&2
        echo "Start Docker Desktop and try again" >&2
        return 1
    fi

    local status
    status=$(gateway_status)
    if [[ "$status" == "running" ]]; then
        return 0
    fi

    # Gateway not running - openshell sandbox create auto-bootstraps a local gateway
    # so we don't need to explicitly start it. Just record that we checked.
    echo "Gateway will be auto-started on first sandbox creation" >&2
    return 0
}

# Stop the gateway (for explicit cleanup)
gateway_stop() {
    if ! openshell_available; then
        return 1
    fi
    openshell gateway stop 2>&1
    return $?
}
