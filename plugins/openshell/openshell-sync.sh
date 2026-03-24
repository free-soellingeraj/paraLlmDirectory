#!/usr/bin/env bash
# openshell-sync.sh - File sync helpers for upload strategy
# Used when OPENSHELL_SYNC_STRATEGY=upload

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/openshell-sandbox.sh"

# Sync files from host to sandbox
# Usage: sync_to_sandbox <sandbox-name> <local-dir> [remote-dir]
sync_to_sandbox() {
    local sandbox_name="$1"
    local local_dir="$2"
    local remote_dir="${3:-/workspace/}"

    if ! openshell_available; then
        echo "ERROR: openshell not available" >&2
        return 1
    fi

    echo "Uploading to sandbox '$sandbox_name'..." >&2
    openshell sandbox upload "$sandbox_name" "$local_dir" "$remote_dir"
    return $?
}

# Sync files from sandbox to host
# Usage: sync_from_sandbox <sandbox-name> <local-dir> [remote-dir]
sync_from_sandbox() {
    local sandbox_name="$1"
    local local_dir="$2"
    local remote_dir="${3:-/workspace/}"

    if ! openshell_available; then
        echo "ERROR: openshell not available" >&2
        return 1
    fi

    echo "Downloading from sandbox '$sandbox_name'..." >&2
    openshell sandbox download "$sandbox_name" "$remote_dir" "$local_dir"
    return $?
}

# Bidirectional sync (upload then download)
# Usage: sync_bidirectional <sandbox-name> <local-dir> [remote-dir]
sync_bidirectional() {
    local sandbox_name="$1"
    local local_dir="$2"
    local remote_dir="${3:-/workspace/}"

    sync_to_sandbox "$sandbox_name" "$local_dir" "$remote_dir" && \
    sync_from_sandbox "$sandbox_name" "$local_dir" "$remote_dir"
}
