#!/usr/bin/env bash
# popup-register.sh - Tmux popup for secret registration
# Launched by the MCP server when Claude calls register_secret
# Handles: display reason, read -s for value, fzf for scope selection
#
# Arguments:
#   $1 - Secret name (e.g., GITHUB_TOKEN)
#   $2 - Reason (e.g., "gh CLI needs GitHub authentication")
#   $3 - Project name (for project-scoped storage)
#   $4 - Sandbox state file path (for task-scoped storage)
#   $5 - Result file path (where to write the outcome)

set -u

# Source user profile for PATH (fzf may be in ~/.fzf/bin)
if [[ -f "$HOME/.bashrc" ]]; then
    source "$HOME/.bashrc" 2>/dev/null || true
elif [[ -f "$HOME/.bash_profile" ]]; then
    source "$HOME/.bash_profile" 2>/dev/null || true
elif [[ -f "$HOME/.profile" ]]; then
    source "$HOME/.profile" 2>/dev/null || true
fi

SECRET_NAME="${1:-}"
REASON="${2:-}"
PROJECT="${3:-}"
SANDBOX_STATE="${4:-}"
RESULT_FILE="${5:-}"

if [[ -z "$SECRET_NAME" || -z "$RESULT_FILE" ]]; then
    echo "Usage: popup-register.sh <name> <reason> <project> <sandbox-state> <result-file>"
    exit 1
fi

# Source secrets helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
source "$PLUGIN_DIR/openshell-secrets.sh"

echo ""
echo "Secret Registration"
echo "==================="
echo ""
echo "  Claude needs: $SECRET_NAME"
if [[ -n "$REASON" ]]; then
    echo "  Reason: $REASON"
fi
echo ""

# Check if already registered
if secret_exists "$SECRET_NAME" "$PROJECT" "$SANDBOX_STATE"; then
    echo "  This secret is already registered."
    echo "  Overwrite? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo '{"success":true,"message":"Secret already registered"}' > "$RESULT_FILE"
        exit 0
    fi
fi

# Read the secret value (silent input)
printf "  Value: "
IFS= read -r -s secret_value
echo ""

if [[ -z "$secret_value" ]]; then
    echo ""
    echo "  Cancelled (empty value)."
    echo '{"success":false,"message":"User cancelled - empty value"}' > "$RESULT_FILE"
    exit 0
fi

# Select scope
echo ""
SCOPE_OPTIONS="This task only"
if [[ -n "$PROJECT" ]]; then
    SCOPE_OPTIONS="${SCOPE_OPTIONS}\nThis project ($PROJECT)"
fi
SCOPE_OPTIONS="${SCOPE_OPTIONS}\nAll projects (global)\nCancel"

SELECTED_SCOPE=$(printf "%b" "$SCOPE_OPTIONS" | fzf --prompt="Register for: " --height=8 --no-info)

case "$SELECTED_SCOPE" in
    "This task only")
        secret_store "$SECRET_NAME" "$secret_value" "task" "$PROJECT" "$SANDBOX_STATE"
        SCOPE_DESC="task"
        ;;
    "This project"*)
        secret_store "$SECRET_NAME" "$secret_value" "project" "$PROJECT" "$SANDBOX_STATE"
        SCOPE_DESC="project"
        ;;
    "All projects (global)")
        secret_store "$SECRET_NAME" "$secret_value" "global" "" ""
        SCOPE_DESC="global"
        ;;
    *)
        echo ""
        echo "  Cancelled."
        echo '{"success":false,"message":"User cancelled scope selection"}' > "$RESULT_FILE"
        exit 0
        ;;
esac

# Clear the secret value from memory
secret_value=""

echo ""
echo "  Secret '$SECRET_NAME' registered (scope: $SCOPE_DESC)"

# Write result for MCP server to read
cat > "$RESULT_FILE" << EOF
{"success":true,"message":"Secret '$SECRET_NAME' registered with scope '$SCOPE_DESC'","scope":"$SCOPE_DESC"}
EOF
