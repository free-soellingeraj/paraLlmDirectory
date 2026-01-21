#!/bin/bash

# Remote utilities for para-llm-directory
# Provides functions for SSH and Coder workspace support

REMOTE_HOSTS_CONFIG="$HOME/.para-llm/remote-hosts.conf"
REMOTE_CACHE_DIR="/tmp/para-llm-remote-cache"

# Ensure cache directory exists
mkdir -p "$REMOTE_CACHE_DIR" 2>/dev/null

# Parse host type from host string (ssh:hostname or coder:workspace)
# Returns: ssh, coder, or empty if invalid
get_host_type() {
    local host="$1"
    case "$host" in
        ssh:*) echo "ssh" ;;
        coder:*) echo "coder" ;;
        *) echo "" ;;
    esac
}

# Parse host name from host string (ssh:hostname -> hostname)
get_host_name() {
    local host="$1"
    echo "${host#*:}"
}

# Load remote hosts from config file and optionally from coder list
# Returns: list of hosts in format ssh:hostname or coder:workspace
load_remote_hosts() {
    local hosts=()

    # Load from config file
    if [[ -f "$REMOTE_HOSTS_CONFIG" ]]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^#.*$ ]] && continue
            [[ -z "${line// }" ]] && continue

            # Handle coder:* wildcard
            if [[ "$line" == "coder:*" ]]; then
                # Auto-discover coder workspaces
                if command -v coder &>/dev/null; then
                    while IFS= read -r ws; do
                        [[ -n "$ws" ]] && hosts+=("coder:$ws")
                    done < <(coder list --output json 2>/dev/null | jq -r '.[].name' 2>/dev/null)
                fi
            else
                hosts+=("$line")
            fi
        done < "$REMOTE_HOSTS_CONFIG"
    fi

    # Output hosts (unique)
    printf '%s\n' "${hosts[@]}" | sort -u
}

# Test if a remote host is reachable (with timeout)
# Returns: 0 if reachable, 1 if not
test_remote_host() {
    local host="$1"
    local timeout="${2:-5}"
    local host_type host_name

    host_type=$(get_host_type "$host")
    host_name=$(get_host_name "$host")

    case "$host_type" in
        ssh)
            ssh -o ConnectTimeout="$timeout" -o BatchMode=yes "$host_name" "echo ok" &>/dev/null
            return $?
            ;;
        coder)
            if command -v coder &>/dev/null; then
                coder ping "$host_name" --timeout "${timeout}s" &>/dev/null
                return $?
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Execute a command on a remote host
# Usage: remote_exec "ssh:hostname" "command"
remote_exec() {
    local host="$1"
    local cmd="$2"
    local host_type host_name

    host_type=$(get_host_type "$host")
    host_name=$(get_host_name "$host")

    case "$host_type" in
        ssh)
            ssh -o ConnectTimeout=10 "$host_name" "$cmd"
            return $?
            ;;
        coder)
            if command -v coder &>/dev/null; then
                coder ssh "$host_name" -- "$cmd"
                return $?
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Discover the code directory on a remote host
# Checks ~/code, ~/projects, /workspace in order
# Returns: path to code directory or empty if not found
discover_remote_code_dir() {
    local host="$1"
    local cache_file="$REMOTE_CACHE_DIR/code-dir-$(echo "$host" | tr ':/' '_')"

    # Check cache (valid for 10 minutes)
    if [[ -f "$cache_file" ]]; then
        local cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt 600 ]]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Check common code directories
    local result
    result=$(remote_exec "$host" '
        for dir in ~/code ~/projects /workspace; do
            if [[ -d "$dir" ]]; then
                echo "$dir"
                exit 0
            fi
        done
        exit 1
    ')

    if [[ -n "$result" ]]; then
        echo "$result" > "$cache_file"
        echo "$result"
        return 0
    fi

    return 1
}

# List git projects on a remote host
# Returns: list of project names (directory names containing .git)
list_remote_projects() {
    local host="$1"
    local code_dir="$2"
    local cache_file="$REMOTE_CACHE_DIR/projects-$(echo "$host" | tr ':/' '_')"

    # Check cache (valid for 5 minutes)
    if [[ -f "$cache_file" ]]; then
        local cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt 300 ]]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Find git repos on remote
    local result
    result=$(remote_exec "$host" "
        find '$code_dir' -maxdepth 2 -name '.git' -type d 2>/dev/null | \
        while read gitdir; do
            dirname \"\$gitdir\" | sed 's|^${code_dir}/||'
        done | grep -v '/' | sort -u
    ")

    if [[ -n "$result" ]]; then
        echo "$result" > "$cache_file"
    fi

    echo "$result"
}

# List branches for a remote project
# Returns: list of branch names
list_remote_branches() {
    local host="$1"
    local code_dir="$2"
    local project="$3"

    remote_exec "$host" "
        cd '$code_dir/$project' 2>/dev/null || exit 1
        git fetch --prune 2>/dev/null
        git branch -r 2>/dev/null | grep -v 'HEAD' | sed 's|origin/||' | sed 's/^[ *]*//' | sort -u
    "
}

# Get SSH command for a remote host
# Returns: the ssh/coder command prefix for interactive sessions
get_ssh_command() {
    local host="$1"
    local host_type host_name

    host_type=$(get_host_type "$host")
    host_name=$(get_host_name "$host")

    case "$host_type" in
        ssh)
            echo "ssh -t $host_name"
            ;;
        coder)
            echo "coder ssh $host_name --"
            ;;
        *)
            return 1
            ;;
    esac
}

# Clear all cached data for remote hosts
clear_remote_cache() {
    rm -rf "$REMOTE_CACHE_DIR"/*
}

# Get a short display name for a host
# ssh:my-server -> my-server
# coder:my-workspace -> my-workspace
get_host_display_name() {
    local host="$1"
    get_host_name "$host"
}
