#!/usr/bin/env bash
# openshell-secrets.sh - Secret storage helpers for OpenShell plugin
# Uses OS keychain (macOS Keychain / Linux secret-tool) when available.
# Falls back to chmod 600 files when no keychain is present.
# Task-scoped secrets always use temporary files (cleaned up on sandbox destroy).
# Secret values NEVER flow through the LLM - only through read -s prompts.

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
else
    echo "para-llm: No bootstrap file found" >&2
    exit 1
fi

OPENSHELL_DIR="$PARA_LLM_ROOT/openshell"

# Keychain service prefix for all para-llm secrets
_KEYCHAIN_SERVICE="para-llm-openshell"

# File-based fallback directory (chmod 600 files, used when no keychain available)
_FILE_SECRETS_DIR="$OPENSHELL_DIR/secrets"

# --- Backend detection ---

# Detect which secret storage backend is available
# Returns: "macos" | "linux" | "file"
_detect_backend() {
    if [[ "$(uname)" == "Darwin" ]] && command -v security &>/dev/null; then
        echo "macos"
    elif command -v secret-tool &>/dev/null; then
        echo "linux"
    else
        echo "file"
    fi
}

# --- File-based fallback backend ---
# Used on systems without OS keychain (servers, WSL, minimal distros)
# Stores secrets in $PARA_LLM_ROOT/openshell/secrets/ with chmod 600

_file_secrets_path() {
    local scope="$1"
    local project="${2:-}"
    case "$scope" in
        global)  echo "$_FILE_SECRETS_DIR/.global.secrets" ;;
        project) echo "$_FILE_SECRETS_DIR/${project}.secrets" ;;
    esac
}

_file_ensure_dir() {
    mkdir -p "$_FILE_SECRETS_DIR"
    chmod 700 "$_FILE_SECRETS_DIR"
}

_file_store() {
    local name="$1"
    local value="$2"
    local scope="$3"
    local project="${4:-}"
    _file_ensure_dir
    local file
    file=$(_file_secrets_path "$scope" "$project")

    # Remove existing entry
    if [[ -f "$file" ]]; then
        local tmp="${file}.tmp"
        grep -v "^${name}=" "$file" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$file"
    fi

    echo "${name}=${value}" >> "$file"
    chmod 600 "$file"
}

_file_get() {
    local name="$1"
    local scope="$2"
    local project="${3:-}"
    local file
    file=$(_file_secrets_path "$scope" "$project")
    if [[ -f "$file" ]]; then
        grep "^${name}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

_file_exists() {
    local name="$1"
    local scope="$2"
    local project="${3:-}"
    local file
    file=$(_file_secrets_path "$scope" "$project")
    [[ -f "$file" ]] && grep -q "^${name}=" "$file" 2>/dev/null
}

_file_remove() {
    local name="$1"
    local scope="$2"
    local project="${3:-}"
    local file
    file=$(_file_secrets_path "$scope" "$project")
    if [[ -f "$file" ]]; then
        local tmp="${file}.tmp"
        grep -v "^${name}=" "$file" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$file"
        chmod 600 "$file"
    fi
}

_file_list() {
    local scope="$1"
    local project="${2:-}"
    local file
    file=$(_file_secrets_path "$scope" "$project")
    if [[ -f "$file" ]]; then
        grep -v '^#' "$file" 2>/dev/null | grep '=' | cut -d'=' -f1
    fi
}

# Build a keychain service name from scope and project
# Usage: _keychain_service <scope> [project]
# Returns: "para-llm-openshell:global" or "para-llm-openshell:project:myproject"
_keychain_service_name() {
    local scope="$1"
    local project="${2:-}"
    case "$scope" in
        global)  echo "${_KEYCHAIN_SERVICE}:global" ;;
        project) echo "${_KEYCHAIN_SERVICE}:project:${project}" ;;
    esac
}

# Store a secret in the OS keychain
# Usage: _keychain_store <name> <value> <scope> [project]
_keychain_store() {
    local name="$1"
    local value="$2"
    local scope="$3"
    local project="${4:-}"
    local service
    service=$(_keychain_service_name "$scope" "$project")
    local backend
    backend=$(_detect_backend)

    case "$backend" in
        macos)
            # Delete existing entry first (ignore errors if not found)
            security delete-generic-password -s "$service" -a "$name" 2>/dev/null || true
            # Add new entry
            security add-generic-password -s "$service" -a "$name" -w "$value" 2>/dev/null
            return $?
            ;;
        linux)
            echo -n "$value" | secret-tool store --label="para-llm: $name ($scope)" \
                service "$service" account "$name" 2>/dev/null
            return $?
            ;;
        file)
            _file_store "$name" "$value" "$scope" "$project"
            return $?
            ;;
    esac
}

# Retrieve a secret
# Usage: _keychain_get <name> <scope> [project]
# Outputs: the secret value
_keychain_get() {
    local name="$1"
    local scope="$2"
    local project="${3:-}"
    local service
    service=$(_keychain_service_name "$scope" "$project")
    local backend
    backend=$(_detect_backend)

    case "$backend" in
        macos)
            security find-generic-password -s "$service" -a "$name" -w 2>/dev/null
            return $?
            ;;
        linux)
            secret-tool lookup service "$service" account "$name" 2>/dev/null
            return $?
            ;;
        file)
            _file_get "$name" "$scope" "$project"
            return $?
            ;;
    esac
}

# Check if a secret exists
# Usage: _keychain_exists <name> <scope> [project]
_keychain_exists() {
    local name="$1"
    local scope="$2"
    local project="${3:-}"
    local service
    service=$(_keychain_service_name "$scope" "$project")
    local backend
    backend=$(_detect_backend)

    case "$backend" in
        macos)
            security find-generic-password -s "$service" -a "$name" &>/dev/null
            return $?
            ;;
        linux)
            secret-tool lookup service "$service" account "$name" &>/dev/null
            return $?
            ;;
        file)
            _file_exists "$name" "$scope" "$project"
            return $?
            ;;
    esac
}

# Remove a secret
# Usage: _keychain_remove <name> <scope> [project]
_keychain_remove() {
    local name="$1"
    local scope="$2"
    local project="${3:-}"
    local service
    service=$(_keychain_service_name "$scope" "$project")
    local backend
    backend=$(_detect_backend)

    case "$backend" in
        macos)
            security delete-generic-password -s "$service" -a "$name" &>/dev/null
            return $?
            ;;
        linux)
            secret-tool clear service "$service" account "$name" &>/dev/null
            return $?
            ;;
        file)
            _file_remove "$name" "$scope" "$project"
            return $?
            ;;
    esac
}

# List all secret names in a keychain scope
# Usage: _keychain_list <scope> [project]
# Outputs: one name per line
_keychain_list() {
    local scope="$1"
    local project="${2:-}"
    local service
    service=$(_keychain_service_name "$scope" "$project")
    local backend
    backend=$(_detect_backend)

    case "$backend" in
        macos)
            # Parse security dump-keychain output for entries matching our service.
            # The 0x00000007 line has the service name, "acct" line has the account.
            # We use sed/grep since macOS awk lacks gawk's match() third arg.
            local _in_block=false
            local _line
            while IFS= read -r _line; do
                # Service appears on 0x00000007 line or "svce" line
                if echo "$_line" | grep -q "=\"${service}\""; then
                    _in_block=true
                    continue
                fi
                if [[ "$_in_block" == true ]] && echo "$_line" | grep -q '"acct"'; then
                    echo "$_line" | sed 's/.*="\(.*\)"/\1/'
                    _in_block=false
                fi
                # Reset on new entry boundary
                if echo "$_line" | grep -q '^keychain:'; then
                    _in_block=false
                fi
            done < <(security dump-keychain 2>/dev/null) | sort -u
            ;;
        linux)
            secret-tool search service "$service" 2>/dev/null | \
                grep "^attribute.account" | \
                sed 's/.*= //' | sort -u
            ;;
        file)
            _file_list "$scope" "$project"
            ;;
    esac
}

# --- Task-scoped secrets (file-based, ephemeral) ---

# Task secrets stay file-based since they're temporary and cleaned up on destroy
_task_secrets_file() {
    local sandbox_state="$1"
    echo "${sandbox_state}.secrets"
}

_task_secret_exists() {
    local name="$1"
    local sandbox_state="$2"
    local file
    file=$(_task_secrets_file "$sandbox_state")
    [[ -f "$file" ]] && grep -q "^${name}=" "$file" 2>/dev/null
}

_task_secret_get() {
    local name="$1"
    local sandbox_state="$2"
    local file
    file=$(_task_secrets_file "$sandbox_state")
    if [[ -f "$file" ]]; then
        grep "^${name}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

_task_secret_store() {
    local name="$1"
    local value="$2"
    local sandbox_state="$3"
    local file
    file=$(_task_secrets_file "$sandbox_state")

    # Remove existing entry if present
    if [[ -f "$file" ]]; then
        local tmp="${file}.tmp"
        grep -v "^${name}=" "$file" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$file"
    fi

    echo "${name}=${value}" >> "$file"
    chmod 600 "$file"
}

_task_secret_remove() {
    local name="$1"
    local sandbox_state="$2"
    local file
    file=$(_task_secrets_file "$sandbox_state")
    if [[ -f "$file" ]]; then
        local tmp="${file}.tmp"
        grep -v "^${name}=" "$file" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$file"
        chmod 600 "$file"
    fi
}

_task_secret_list() {
    local sandbox_state="$1"
    local file
    file=$(_task_secrets_file "$sandbox_state")
    if [[ -f "$file" ]]; then
        grep -v '^#' "$file" 2>/dev/null | grep '=' | cut -d'=' -f1
    fi
}

# --- Public API ---

# Check if a secret is available (any scope: task, project, global)
# Usage: secret_exists <name> [project] [sandbox-state-file]
# Returns: 0 if found, 1 if not
secret_exists() {
    local name="$1"
    local project="${2:-}"
    local sandbox_state="${3:-}"

    # Check task-scoped
    if [[ -n "$sandbox_state" ]] && _task_secret_exists "$name" "$sandbox_state"; then
        return 0
    fi

    # Check project-scoped
    if [[ -n "$project" ]] && _keychain_exists "$name" "project" "$project"; then
        return 0
    fi

    # Check global
    if _keychain_exists "$name" "global"; then
        return 0
    fi

    return 1
}

# Get a secret value (checks scopes in order: task, project, global)
# Usage: secret_get <name> [project] [sandbox-state-file]
# Outputs the value
secret_get() {
    local name="$1"
    local project="${2:-}"
    local sandbox_state="${3:-}"
    local value=""

    # Task-scoped
    if [[ -n "$sandbox_state" ]]; then
        value=$(_task_secret_get "$name" "$sandbox_state")
        [[ -n "$value" ]] && echo "$value" && return 0
    fi

    # Project-scoped
    if [[ -n "$project" ]]; then
        value=$(_keychain_get "$name" "project" "$project")
        [[ -n "$value" ]] && echo "$value" && return 0
    fi

    # Global
    value=$(_keychain_get "$name" "global")
    [[ -n "$value" ]] && echo "$value" && return 0

    return 1
}

# Store a secret at a specific scope
# Usage: secret_store <name> <value> <scope> [project] [sandbox-state-file]
# scope: global | project | task
secret_store() {
    local name="$1"
    local value="$2"
    local scope="$3"
    local project="${4:-}"
    local sandbox_state="${5:-}"

    case "$scope" in
        global)
            _keychain_store "$name" "$value" "global"
            ;;
        project)
            if [[ -z "$project" ]]; then
                echo "ERROR: project name required for project scope" >&2
                return 1
            fi
            _keychain_store "$name" "$value" "project" "$project"
            ;;
        task)
            if [[ -z "$sandbox_state" ]]; then
                echo "ERROR: sandbox state file required for task scope" >&2
                return 1
            fi
            _task_secret_store "$name" "$value" "$sandbox_state"
            ;;
        *)
            echo "ERROR: unknown scope '$scope'" >&2
            return 1
            ;;
    esac
}

# Remove a secret from a specific scope
# Usage: secret_remove <name> <scope> [project]
secret_remove() {
    local name="$1"
    local scope="$2"
    local project="${3:-}"

    case "$scope" in
        global)
            _keychain_remove "$name" "global"
            ;;
        project)
            if [[ -z "$project" ]]; then
                echo "ERROR: project name required for project scope" >&2
                return 1
            fi
            _keychain_remove "$name" "project" "$project"
            ;;
        *)
            echo "ERROR: can only remove from global or project scope" >&2
            return 1
            ;;
    esac
}

# List all secret names (never values) across all scopes
# Usage: secret_list [project] [sandbox-state-file]
# Outputs: one name per line (deduplicated)
secret_list() {
    local project="${1:-}"
    local sandbox_state="${2:-}"
    local names=""

    # Global
    names+=$(_keychain_list "global")
    names+=$'\n'

    # Project
    if [[ -n "$project" ]]; then
        names+=$(_keychain_list "project" "$project")
        names+=$'\n'
    fi

    # Task
    if [[ -n "$sandbox_state" ]]; then
        names+=$(_task_secret_list "$sandbox_state")
        names+=$'\n'
    fi

    # Deduplicate and output
    echo "$names" | sort -u | grep -v '^$'
}

# List all secrets with their scope (never values)
# Usage: secret_list_with_scope [project] [sandbox-state-file]
# Outputs: "name scope" per line (e.g., "GITHUB_TOKEN global")
# If a secret exists in multiple scopes, shows the narrowest (task > project > global)
secret_list_with_scope() {
    local project="${1:-}"
    local sandbox_state="${2:-}"

    declare -A seen

    # Task (narrowest scope - wins over others)
    if [[ -n "$sandbox_state" ]]; then
        local task_names
        task_names=$(_task_secret_list "$sandbox_state")
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            seen["$name"]="task"
        done <<< "$task_names"
    fi

    # Project
    if [[ -n "$project" ]]; then
        local proj_names
        proj_names=$(_keychain_list "project" "$project")
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            [[ -z "${seen[$name]:-}" ]] && seen["$name"]="project"
        done <<< "$proj_names"
    fi

    # Global (widest scope)
    local global_names
    global_names=$(_keychain_list "global")
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ -z "${seen[$name]:-}" ]] && seen["$name"]="global"
    done <<< "$global_names"

    # Output sorted
    for name in $(echo "${!seen[@]}" | tr ' ' '\n' | sort); do
        echo "$name ${seen[$name]}"
    done
}

# Collect all secrets for a sandbox as --env flags
# Usage: secret_collect_env_flags [project] [sandbox-state-file]
# Outputs: --env NAME=value flags for openshell sandbox create
secret_collect_env_flags() {
    local project="${1:-}"
    local sandbox_state="${2:-}"

    local names
    names=$(secret_list "$project" "$sandbox_state")

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local value
        value=$(secret_get "$name" "$project" "$sandbox_state") || continue
        echo "--env"
        echo "${name}=${value}"
    done <<< "$names"
}
