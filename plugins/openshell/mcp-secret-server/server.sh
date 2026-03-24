#!/usr/bin/env bash
# server.sh - MCP server for secret registration
# Implements JSON-RPC over stdio (MCP protocol)
# Exposes tools: register_secret, list_secrets, check_secret
#
# Usage: server.sh --para-llm-root /path/to/root

set -u

# Parse arguments
PARA_LLM_ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --para-llm-root)
            PARA_LLM_ROOT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -z "$PARA_LLM_ROOT" ]]; then
    # Fallback to bootstrap pointer
    BOOTSTRAP_FILE="$HOME/.para-llm-root"
    if [[ -f "$BOOTSTRAP_FILE" ]]; then
        PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    else
        PARA_LLM_ROOT="$HOME/.para-llm-directory"
    fi
fi
export PARA_LLM_ROOT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Source secrets helpers
source "$PLUGIN_DIR/openshell-secrets.sh"

# Source config for project context
if [[ -f "$PARA_LLM_ROOT/config" ]]; then
    source "$PARA_LLM_ROOT/config"
fi

OPENSHELL_DIR="$PARA_LLM_ROOT/openshell"
SANDBOX_STATE_DIR="$OPENSHELL_DIR/state/sandboxes"

# --- JSON helpers ---

# Minimal JSON string escaping
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    echo "$s"
}

# Extract a string value from JSON by key (simple, no nesting)
json_get() {
    local json="$1"
    local key="$2"
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# Extract a value (string or other) from JSON by key
json_get_any() {
    local json="$1"
    local key="$2"
    # Try string first
    local val
    val=$(json_get "$json" "$key")
    if [[ -n "$val" ]]; then
        echo "$val"
        return
    fi
    # Try non-string (number, bool, null)
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p" | head -1 | tr -d ' '
}

# --- Detect current project/sandbox context ---

# Try to figure out which project/sandbox the current session is for
# by checking tmux pane CWD against known sandbox state files
detect_context() {
    local pane_path=""

    # Try to get current tmux pane's working directory
    if command -v tmux &>/dev/null && [[ -n "${TMUX:-}" ]]; then
        pane_path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)
    fi

    # Fallback to PWD
    pane_path="${pane_path:-${PWD:-}}"

    CURRENT_PROJECT=""
    CURRENT_BRANCH=""
    CURRENT_SANDBOX_STATE=""

    # Match against sandbox state files
    if [[ -d "$SANDBOX_STATE_DIR" ]]; then
        for state_file in "$SANDBOX_STATE_DIR"/*; do
            [[ -f "$state_file" ]] || continue
            local env_dir
            env_dir=$(grep "^ENV_DIR=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
            if [[ -n "$env_dir" && "$pane_path" == "$env_dir"* ]]; then
                CURRENT_PROJECT=$(grep "^PROJECT=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
                CURRENT_BRANCH=$(grep "^BRANCH=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
                CURRENT_SANDBOX_STATE="$state_file"
                return
            fi
        done
    fi

    # Try to derive from ENVS_DIR path
    local envs_dir="${PARA_LLM_ROOT}/envs"
    if [[ "$pane_path" == "$envs_dir"* ]]; then
        local rel="${pane_path#$envs_dir/}"
        local env_name="${rel%%/*}"
        # env_name format: ProjectName-branch-name
        CURRENT_PROJECT="${env_name%%-*}"
        CURRENT_BRANCH="${env_name#*-}"
    fi
}

# --- MCP Protocol ---

send_response() {
    local id="$1"
    local result="$2"
    printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$result"
}

send_error() {
    local id="$1"
    local code="$2"
    local message="$3"
    local escaped_msg
    escaped_msg=$(json_escape "$message")
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\n' "$id" "$code" "$escaped_msg"
}

handle_initialize() {
    local id="$1"
    send_response "$id" '{
        "protocolVersion": "2024-11-05",
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "para-llm-secrets", "version": "1.0.0"}
    }'
}

handle_tools_list() {
    local id="$1"
    send_response "$id" '{
        "tools": [
            {
                "name": "register_secret",
                "description": "Register a secret (API key, token, etc.) that is needed for an operation. This opens an interactive popup where the user enters the secret value securely - the value never passes through the LLM. Call this when you encounter authentication errors (401, 403) or when you know a secret is needed before attempting an operation.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": {
                            "type": "string",
                            "description": "The environment variable name for the secret (e.g., GITHUB_TOKEN, ANTHROPIC_API_KEY, NPM_TOKEN)"
                        },
                        "reason": {
                            "type": "string",
                            "description": "A brief explanation of why this secret is needed, shown to the user in the registration popup"
                        }
                    },
                    "required": ["name", "reason"]
                }
            },
            {
                "name": "list_secrets",
                "description": "List the names of all registered secrets (never returns values). Use this to check what secrets are available before attempting operations that require authentication.",
                "inputSchema": {
                    "type": "object",
                    "properties": {}
                }
            },
            {
                "name": "check_secret",
                "description": "Check if a specific secret is registered. Returns true/false. Use this proactively before attempting authenticated operations.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "name": {
                            "type": "string",
                            "description": "The secret name to check (e.g., GITHUB_TOKEN)"
                        }
                    },
                    "required": ["name"]
                }
            }
        ]
    }'
}

handle_tool_call() {
    local id="$1"
    local json="$2"

    # Extract tool name - must get params.name, not arguments.name
    # Use a two-step approach: first extract params object, then get name from it
    local tool_name
    tool_name=$(echo "$json" | sed -n 's/.*"params"[[:space:]]*:[[:space:]]*{[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    local args_json
    # Extract the arguments object - everything between "arguments": { and the matching }
    args_json=$(echo "$json" | sed -n 's/.*"arguments"[[:space:]]*:[[:space:]]*\({[^}]*}\).*/\1/p')

    detect_context

    case "$tool_name" in
        register_secret)
            local secret_name reason
            secret_name=$(json_get "$args_json" "name")
            reason=$(json_get "$args_json" "reason")

            if [[ -z "$secret_name" ]]; then
                send_error "$id" -32602 "Missing required parameter: name"
                return
            fi

            # Create a temporary result file
            local result_file
            result_file=$(mktemp /tmp/para-llm-secret-result.XXXXXX)

            # Launch tmux popup for interactive registration
            local popup_script="$SCRIPT_DIR/popup-register.sh"

            if command -v tmux &>/dev/null && [[ -n "${TMUX:-}" ]]; then
                # Run popup in tmux
                tmux display-popup -E -w 60% -h 50% \
                    "bash '$popup_script' '$secret_name' '$reason' '$CURRENT_PROJECT' '$CURRENT_SANDBOX_STATE' '$result_file'"

                # Read the result
                if [[ -f "$result_file" ]]; then
                    local result
                    result=$(cat "$result_file")
                    rm -f "$result_file"

                    local success
                    success=$(json_get_any "$result" "success")
                    local message
                    message=$(json_get "$result" "message")
                    message=$(json_escape "$message")

                    if [[ "$success" == "true" ]]; then
                        # If sandbox is running, inject the secret
                        if [[ -n "$CURRENT_SANDBOX_STATE" ]]; then
                            local sandbox_name
                            sandbox_name=$(basename "$CURRENT_SANDBOX_STATE")
                            local secret_val
                            secret_val=$(secret_get "$secret_name" "$CURRENT_PROJECT" "$CURRENT_SANDBOX_STATE")
                            if [[ -n "$secret_val" ]]; then
                                # Inject into running sandbox
                                openshell sandbox exec "$sandbox_name" -- sh -c "export ${secret_name}='${secret_val}'" 2>/dev/null || true
                            fi
                        fi

                        send_response "$id" "{\"content\":[{\"type\":\"text\",\"text\":\"${message}\"}]}"
                    else
                        send_response "$id" "{\"content\":[{\"type\":\"text\",\"text\":\"${message}\"}]}"
                    fi
                else
                    rm -f "$result_file"
                    send_response "$id" '{"content":[{"type":"text","text":"Secret registration popup was closed without completing"}]}'
                fi
            else
                # No tmux - fall back to direct stdio (less ideal)
                rm -f "$result_file"
                send_error "$id" -32603 "Cannot open registration popup: no tmux session detected"
            fi
            ;;

        list_secrets)
            local names
            names=$(secret_list "$CURRENT_PROJECT" "$CURRENT_SANDBOX_STATE")
            local names_json="[]"
            if [[ -n "$names" ]]; then
                names_json="["
                local first=true
                while IFS= read -r name; do
                    [[ -z "$name" ]] && continue
                    if [[ "$first" == true ]]; then
                        first=false
                    else
                        names_json+=","
                    fi
                    names_json+="\"$(json_escape "$name")\""
                done <<< "$names"
                names_json+="]"
            fi

            send_response "$id" "{\"content\":[{\"type\":\"text\",\"text\":\"Registered secrets: ${names_json}\"}]}"
            ;;

        check_secret)
            local check_name
            check_name=$(json_get "$args_json" "name")

            if [[ -z "$check_name" ]]; then
                send_error "$id" -32602 "Missing required parameter: name"
                return
            fi

            if secret_exists "$check_name" "$CURRENT_PROJECT" "$CURRENT_SANDBOX_STATE"; then
                send_response "$id" "{\"content\":[{\"type\":\"text\",\"text\":\"Secret '${check_name}' is registered and available.\"}]}"
            else
                send_response "$id" "{\"content\":[{\"type\":\"text\",\"text\":\"Secret '${check_name}' is NOT registered. Use register_secret to add it.\"}]}"
            fi
            ;;

        *)
            send_error "$id" -32601 "Unknown tool: $tool_name"
            ;;
    esac
}

# --- Main loop ---

# Read JSON-RPC messages from stdin, one per line
while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Extract method and id
    method=$(json_get "$line" "method")
    id=$(json_get_any "$line" "id")

    case "$method" in
        initialize)
            handle_initialize "$id"
            ;;
        notifications/initialized)
            # No response needed for notifications
            ;;
        tools/list)
            handle_tools_list "$id"
            ;;
        tools/call)
            handle_tool_call "$id" "$line"
            ;;
        *)
            if [[ -n "$id" ]]; then
                send_error "$id" -32601 "Method not found: $method"
            fi
            ;;
    esac
done
