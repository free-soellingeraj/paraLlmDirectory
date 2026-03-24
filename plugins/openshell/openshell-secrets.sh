#!/usr/bin/env bash
# openshell-secrets.sh - Secret storage helpers for OpenShell plugin
# Manages .secrets files at global/project/task scopes
# Secret values NEVER flow through the LLM - only through read -s prompts

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
GLOBAL_SECRETS="$OPENSHELL_DIR/.secrets"
PROJECT_SECRETS_DIR="$OPENSHELL_DIR/secrets"

# Ensure directories and files exist with correct permissions
_ensure_secrets_dirs() {
    mkdir -p "$PROJECT_SECRETS_DIR"
    if [[ ! -f "$GLOBAL_SECRETS" ]]; then
        touch "$GLOBAL_SECRETS"
        chmod 600 "$GLOBAL_SECRETS"
    fi
}

# Get the path to a project's secrets file
# Usage: _project_secrets_file <project-name>
_project_secrets_file() {
    local project="$1"
    echo "$PROJECT_SECRETS_DIR/${project}.secrets"
}

# Check if a secret exists in a specific secrets file
# Usage: _secret_exists_in_file <file> <name>
# Returns: 0 if found, 1 if not
_secret_exists_in_file() {
    local file="$1"
    local name="$2"
    [[ -f "$file" ]] && grep -q "^${name}=" "$file" 2>/dev/null
}

# Read a secret value from a specific secrets file
# Usage: _read_secret_from_file <file> <name>
# Outputs the value (or empty if not found)
_read_secret_from_file() {
    local file="$1"
    local name="$2"
    if [[ -f "$file" ]]; then
        grep "^${name}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

# Write a secret to a specific secrets file
# Usage: _write_secret_to_file <file> <name> <value>
_write_secret_to_file() {
    local file="$1"
    local name="$2"
    local value="$3"

    _ensure_secrets_dirs

    # Remove existing entry if present
    if [[ -f "$file" ]]; then
        local tmp="${file}.tmp"
        grep -v "^${name}=" "$file" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$file"
    fi

    # Append new entry
    echo "${name}=${value}" >> "$file"
    chmod 600 "$file"
}

# Remove a secret from a specific secrets file
# Usage: _remove_secret_from_file <file> <name>
_remove_secret_from_file() {
    local file="$1"
    local name="$2"
    if [[ -f "$file" ]]; then
        local tmp="${file}.tmp"
        grep -v "^${name}=" "$file" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$file"
        chmod 600 "$file"
    fi
}

# --- Public API ---

# Check if a secret is available (any scope: task state, project, global)
# Usage: secret_exists <name> [project] [sandbox-state-file]
# Returns: 0 if found, 1 if not
secret_exists() {
    local name="$1"
    local project="${2:-}"
    local sandbox_state="${3:-}"

    # Check task-scoped (sandbox state file)
    if [[ -n "$sandbox_state" ]] && _secret_exists_in_file "$sandbox_state.secrets" "$name"; then
        return 0
    fi

    # Check project-scoped
    if [[ -n "$project" ]]; then
        local pfile
        pfile=$(_project_secrets_file "$project")
        if _secret_exists_in_file "$pfile" "$name"; then
            return 0
        fi
    fi

    # Check global
    if _secret_exists_in_file "$GLOBAL_SECRETS" "$name"; then
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
        value=$(_read_secret_from_file "$sandbox_state.secrets" "$name")
        [[ -n "$value" ]] && echo "$value" && return 0
    fi

    # Project-scoped
    if [[ -n "$project" ]]; then
        local pfile
        pfile=$(_project_secrets_file "$project")
        value=$(_read_secret_from_file "$pfile" "$name")
        [[ -n "$value" ]] && echo "$value" && return 0
    fi

    # Global
    value=$(_read_secret_from_file "$GLOBAL_SECRETS" "$name")
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

    _ensure_secrets_dirs

    case "$scope" in
        global)
            _write_secret_to_file "$GLOBAL_SECRETS" "$name" "$value"
            ;;
        project)
            if [[ -z "$project" ]]; then
                echo "ERROR: project name required for project scope" >&2
                return 1
            fi
            local pfile
            pfile=$(_project_secrets_file "$project")
            _write_secret_to_file "$pfile" "$name" "$value"
            ;;
        task)
            if [[ -z "$sandbox_state" ]]; then
                echo "ERROR: sandbox state file required for task scope" >&2
                return 1
            fi
            _write_secret_to_file "$sandbox_state.secrets" "$name" "$value"
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
            _remove_secret_from_file "$GLOBAL_SECRETS" "$name"
            ;;
        project)
            if [[ -z "$project" ]]; then
                echo "ERROR: project name required for project scope" >&2
                return 1
            fi
            local pfile
            pfile=$(_project_secrets_file "$project")
            _remove_secret_from_file "$pfile" "$name"
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
    if [[ -f "$GLOBAL_SECRETS" ]]; then
        names+=$(grep -v '^#' "$GLOBAL_SECRETS" 2>/dev/null | grep '=' | cut -d'=' -f1)
        names+=$'\n'
    fi

    # Project
    if [[ -n "$project" ]]; then
        local pfile
        pfile=$(_project_secrets_file "$project")
        if [[ -f "$pfile" ]]; then
            names+=$(grep -v '^#' "$pfile" 2>/dev/null | grep '=' | cut -d'=' -f1)
            names+=$'\n'
        fi
    fi

    # Task
    if [[ -n "$sandbox_state" && -f "$sandbox_state.secrets" ]]; then
        names+=$(grep -v '^#' "$sandbox_state.secrets" 2>/dev/null | grep '=' | cut -d'=' -f1)
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

    # Collect from each scope, tracking which scope each came from
    declare -A seen

    # Task (narrowest scope - wins over others)
    if [[ -n "$sandbox_state" && -f "$sandbox_state.secrets" ]]; then
        while IFS='=' read -r name _; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            seen["$name"]="task"
        done < "$sandbox_state.secrets"
    fi

    # Project
    if [[ -n "$project" ]]; then
        local pfile
        pfile=$(_project_secrets_file "$project")
        if [[ -f "$pfile" ]]; then
            while IFS='=' read -r name _; do
                [[ -z "$name" || "$name" == \#* ]] && continue
                [[ -z "${seen[$name]:-}" ]] && seen["$name"]="project"
            done < "$pfile"
        fi
    fi

    # Global (widest scope)
    if [[ -f "$GLOBAL_SECRETS" ]]; then
        while IFS='=' read -r name _; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            [[ -z "${seen[$name]:-}" ]] && seen["$name"]="global"
        done < "$GLOBAL_SECRETS"
    fi

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
