#!/usr/bin/env bash
# ssh.sh - SSH/rsync backend for remote save
# Implements: backend_push, backend_pull, backend_test, backend_list
#
# Expected variables (sourced from remote config before calling):
#   REMOTE_HOST      - SSH host (e.g., user@host)
#   REMOTE_DIR       - Remote directory path
#   REMOTE_SSH_KEY   - Optional SSH key path
#   REMOTE_SSH_PORT  - Optional SSH port (default: 22)

_ssh_opts() {
    local opts=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
    if [[ -n "${REMOTE_SSH_KEY:-}" ]]; then
        opts+=(-i "$REMOTE_SSH_KEY")
    fi
    if [[ -n "${REMOTE_SSH_PORT:-}" && "${REMOTE_SSH_PORT:-}" != "22" ]]; then
        opts+=(-p "$REMOTE_SSH_PORT")
    fi
    echo "${opts[@]}"
}

_rsync_ssh_cmd() {
    local cmd="ssh -o BatchMode=yes -o ConnectTimeout=5"
    if [[ -n "${REMOTE_SSH_KEY:-}" ]]; then
        cmd="$cmd -i $REMOTE_SSH_KEY"
    fi
    if [[ -n "${REMOTE_SSH_PORT:-}" && "${REMOTE_SSH_PORT:-}" != "22" ]]; then
        cmd="$cmd -p $REMOTE_SSH_PORT"
    fi
    echo "$cmd"
}

_rsync_opts() {
    local opts=(-az --timeout=10)
    opts+=(-e "$(_rsync_ssh_cmd)")
    echo "${opts[@]}"
}

backend_test() {
    local ssh_opts
    read -ra ssh_opts <<< "$(_ssh_opts)"
    ssh "${ssh_opts[@]}" "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR' && echo ok" 2>/dev/null
    return $?
}

backend_push() {
    local local_dir="$1"
    local rsync_opts
    read -ra rsync_opts <<< "$(_rsync_opts)"

    # Ensure remote directory exists
    local ssh_opts
    read -ra ssh_opts <<< "$(_ssh_opts)"
    ssh "${ssh_opts[@]}" "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR'" 2>/dev/null || return 1

    # Push files
    rsync "${rsync_opts[@]}" "$local_dir/" "$REMOTE_HOST:$REMOTE_DIR/" 2>/dev/null
    return $?
}

backend_pull() {
    local local_dir="$1"
    local rsync_opts
    read -ra rsync_opts <<< "$(_rsync_opts)"

    mkdir -p "$local_dir"
    rsync "${rsync_opts[@]}" "$REMOTE_HOST:$REMOTE_DIR/" "$local_dir/" 2>/dev/null
    return $?
}

backend_list() {
    local ssh_opts
    read -ra ssh_opts <<< "$(_ssh_opts)"
    ssh "${ssh_opts[@]}" "$REMOTE_HOST" "ls -la '$REMOTE_DIR/' 2>/dev/null" 2>/dev/null
    return $?
}
