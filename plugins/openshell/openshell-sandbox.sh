#!/usr/bin/env bash
# openshell-sandbox.sh - Sandbox lifecycle management
# Create, connect, destroy, and query OpenShell sandboxes

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers
source "$SCRIPT_DIR/openshell-gateway.sh"
source "$SCRIPT_DIR/openshell-secrets.sh"

OPENSHELL_DIR="$PARA_LLM_ROOT/openshell"
SANDBOX_STATE_DIR="$OPENSHELL_DIR/state/sandboxes"

mkdir -p "$SANDBOX_STATE_DIR"

# --- Naming ---

# Generate a deterministic sandbox name from project and branch
# Usage: sandbox_name_for_env <project> <branch>
sandbox_name_for_env() {
    local project="$1"
    local branch="$2"
    # Sanitize: lowercase, replace non-alphanumeric with dash, trim dashes
    local name="para-${project}-${branch}"
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    echo "$name"
}

# --- State tracking ---

# Get the state file path for a sandbox
_state_file() {
    local sandbox_name="$1"
    echo "$SANDBOX_STATE_DIR/$sandbox_name"
}

# Check if an environment has an associated sandbox
# Usage: is_env_sandboxed <project> <branch>
is_env_sandboxed() {
    local project="$1"
    local branch="$2"
    local name
    name=$(sandbox_name_for_env "$project" "$branch")
    [[ -f "$(_state_file "$name")" ]]
}

# Get sandbox name for a given environment directory
# Usage: get_sandbox_for_env <env-dir>
get_sandbox_for_env() {
    local env_dir="$1"
    for state_file in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$state_file" ]] || continue
        local stored_env_dir
        stored_env_dir=$(grep "^ENV_DIR=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        if [[ "$stored_env_dir" == "$env_dir" ]]; then
            basename "$state_file"
            return 0
        fi
    done
    return 1
}

# List all tracked sandboxes
# Outputs: sandbox_name|project|branch|status per line
list_sandboxed_envs() {
    for state_file in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$state_file" ]] || continue
        local name project branch
        name=$(basename "$state_file")
        # Source the state file to get variables
        (
            source "$state_file"
            local status="unknown"
            if openshell_available; then
                if openshell sandbox get "$name" &>/dev/null; then
                    status="running"
                else
                    status="stopped"
                fi
            fi
            echo "${name}|${PROJECT:-}|${BRANCH:-}|${status}"
        )
    done
}

# --- Policy resolution ---

# Resolve which policy file to use for a sandbox
# Usage: resolve_policy <project> <env-dir>
# Outputs: path to policy YAML, or empty for default
resolve_policy() {
    local project="$1"
    local env_dir="$2"

    # Source config for OPENSHELL_DEFAULT_POLICY
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi

    # 1. Project-specific policy in repo
    local repo_policy="$env_dir/.openshell-policy.yaml"
    if [[ -f "$repo_policy" ]]; then
        echo "$repo_policy"
        return 0
    fi

    # 2. User per-project override
    local user_project_policy="$OPENSHELL_DIR/policies/${project}.yaml"
    if [[ -f "$user_project_policy" ]]; then
        echo "$user_project_policy"
        return 0
    fi

    # 3. User global default
    local user_default="$OPENSHELL_DIR/policies/default.yaml"
    if [[ -f "$user_default" ]]; then
        echo "$user_default"
        return 0
    fi

    # 4. Config override
    if [[ -n "${OPENSHELL_DEFAULT_POLICY:-}" && -f "${OPENSHELL_DEFAULT_POLICY}" ]]; then
        echo "$OPENSHELL_DEFAULT_POLICY"
        return 0
    fi

    # 5. Shipped default
    local shipped_default="$SCRIPT_DIR/policies/default.yaml"
    if [[ -f "$shipped_default" ]]; then
        echo "$shipped_default"
        return 0
    fi

    # No policy found - let openshell use its built-in default
    echo ""
}

# --- Lifecycle ---

# Create a new sandbox for an environment
# Usage: sandbox_create <project> <branch> <env-dir> <clone-dir>
# Returns: 0 on success, 1 on failure
sandbox_create() {
    local project="$1"
    local branch="$2"
    local env_dir="$3"
    local clone_dir="$4"

    local sandbox_name
    sandbox_name=$(sandbox_name_for_env "$project" "$branch")

    # Ensure gateway
    if ! ensure_gateway; then
        echo "WARN: Cannot start OpenShell gateway, falling back to host execution" >&2
        return 1
    fi

    # Resolve policy
    local policy
    policy=$(resolve_policy "$project" "$clone_dir")
    local policy_flag=""
    if [[ -n "$policy" ]]; then
        policy_flag="--policy $policy"
    fi

    # Collect secrets as --env flags
    local state_file
    state_file=$(_state_file "$sandbox_name")
    local env_flags=()
    while IFS= read -r flag; do
        [[ -n "$flag" ]] && env_flags+=("$flag")
    done < <(secret_collect_env_flags "$project" "$state_file")

    # Source config for sync strategy
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
    local sync_strategy="${OPENSHELL_SYNC_STRATEGY:-git}"

    # Create the sandbox
    local create_cmd=(openshell sandbox create --name "$sandbox_name")
    [[ -n "$policy_flag" ]] && create_cmd+=($policy_flag)
    create_cmd+=("${env_flags[@]}")
    create_cmd+=(-- claude --dangerously-skip-permissions)

    echo "Creating OpenShell sandbox '$sandbox_name'..." >&2
    if ! "${create_cmd[@]}" 2>&1; then
        echo "ERROR: Failed to create sandbox" >&2
        return 1
    fi

    # Sync code
    if [[ "$sync_strategy" == "upload" ]]; then
        echo "Uploading code to sandbox..." >&2
        if ! openshell sandbox upload "$sandbox_name" "$clone_dir" /workspace/ 2>&1; then
            echo "WARN: Code upload failed" >&2
        fi
    fi
    # For git strategy, the sandbox clones from the remote internally

    # Write state file
    cat > "$state_file" << STATE_EOF
# para-llm openshell sandbox state
SANDBOX_NAME="$sandbox_name"
ENV_DIR="$env_dir"
PROJECT="$project"
BRANCH="$branch"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
POLICY_FILE="${policy:-default}"
SYNC_STRATEGY="$sync_strategy"
STATE_EOF

    echo "Sandbox '$sandbox_name' created" >&2
    return 0
}

# Connect to an existing sandbox
# Usage: sandbox_connect <project> <branch>
# Returns: 0 on success, 1 on failure
sandbox_connect() {
    local project="$1"
    local branch="$2"

    local sandbox_name
    sandbox_name=$(sandbox_name_for_env "$project" "$branch")

    if ! openshell_available; then
        return 1
    fi

    # Check if sandbox exists
    if openshell sandbox get "$sandbox_name" &>/dev/null; then
        openshell sandbox connect "$sandbox_name"
        return $?
    else
        echo "Sandbox '$sandbox_name' not found" >&2
        return 1
    fi
}

# Destroy a sandbox and clean up state
# Usage: sandbox_destroy <project> <branch> [clone-dir]
# Returns: 0 on success, 1 on failure (non-fatal)
sandbox_destroy() {
    local project="$1"
    local branch="$2"
    local clone_dir="${3:-}"

    local sandbox_name
    sandbox_name=$(sandbox_name_for_env "$project" "$branch")
    local state_file
    state_file=$(_state_file "$sandbox_name")

    # Source state file for sync strategy
    local sync_strategy="git"
    if [[ -f "$state_file" ]]; then
        sync_strategy=$(grep "^SYNC_STRATEGY=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        sync_strategy="${sync_strategy:-git}"
    fi

    # Sync back uncommitted work if using upload strategy
    if [[ "$sync_strategy" == "upload" && -n "$clone_dir" ]]; then
        echo "Syncing changes from sandbox before destruction..." >&2
        openshell sandbox download "$sandbox_name" /workspace/ "$clone_dir" 2>/dev/null || true
    fi

    # Delete the sandbox
    if openshell_available; then
        echo "Destroying sandbox '$sandbox_name'..." >&2
        openshell sandbox delete "$sandbox_name" 2>&1 || {
            echo "WARN: Failed to delete sandbox '$sandbox_name'" >&2
        }
    fi

    # Clean up state file and task-scoped secrets
    rm -f "$state_file"
    rm -f "$state_file.secrets"

    return 0
}

# Check if a sandbox exists and is running
# Usage: sandbox_exists <project> <branch>
# Returns: 0 if exists and running, 1 otherwise
sandbox_exists() {
    local project="$1"
    local branch="$2"

    local sandbox_name
    sandbox_name=$(sandbox_name_for_env "$project" "$branch")

    if ! openshell_available; then
        return 1
    fi

    openshell sandbox get "$sandbox_name" &>/dev/null
    return $?
}

# Get sandbox status string
# Usage: sandbox_status <project> <branch>
# Outputs: running | stopped | not-found
sandbox_status() {
    local project="$1"
    local branch="$2"

    local sandbox_name
    sandbox_name=$(sandbox_name_for_env "$project" "$branch")

    if ! openshell_available; then
        echo "not-installed"
        return
    fi

    if openshell sandbox get "$sandbox_name" &>/dev/null; then
        echo "running"
    elif [[ -f "$(_state_file "$sandbox_name")" ]]; then
        echo "stopped"
    else
        echo "not-found"
    fi
}
