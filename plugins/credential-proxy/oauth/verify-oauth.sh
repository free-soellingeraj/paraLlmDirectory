#!/usr/bin/env bash
set -euo pipefail

# Verify OAuth tokens are still valid for configured tools
# Usage: verify-oauth.sh [--quiet]
#
# Exit 0 if all configured tools are authenticated.
# Exit 1 if any configured tool needs re-authentication.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load para-llm config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
fi

CONFIG_FILE="${PARA_LLM_ROOT:-}/plugins/credential-proxy/credentials.yaml"
QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

FAILURES=0

check_gcloud() {
    if ! command -v gcloud &>/dev/null; then
        [[ "$QUIET" == false ]] && echo "  gcloud: not installed (skipping)"
        return
    fi
    if gcloud auth print-access-token &>/dev/null; then
        [[ "$QUIET" == false ]] && echo "  gcloud: ok"
    else
        [[ "$QUIET" == false ]] && echo "  gcloud: NOT AUTHENTICATED - run 'gcloud auth login'"
        ((FAILURES++))
    fi
}

check_gh() {
    if ! command -v gh &>/dev/null; then
        [[ "$QUIET" == false ]] && echo "  gh: not installed (skipping)"
        return
    fi
    if gh auth status &>/dev/null; then
        [[ "$QUIET" == false ]] && echo "  gh: ok"
    else
        [[ "$QUIET" == false ]] && echo "  gh: NOT AUTHENTICATED - run 'gh auth login'"
        ((FAILURES++))
    fi
}

check_az() {
    if ! command -v az &>/dev/null; then
        [[ "$QUIET" == false ]] && echo "  az: not installed (skipping)"
        return
    fi
    if az account show &>/dev/null; then
        [[ "$QUIET" == false ]] && echo "  az: ok"
    else
        [[ "$QUIET" == false ]] && echo "  az: NOT AUTHENTICATED - run 'az login'"
        ((FAILURES++))
    fi
}

[[ "$QUIET" == false ]] && echo "Checking OAuth tokens..."

# Check which tools are configured
if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
    [[ "$(yq '.oauth.gcloud.enabled // false' "$CONFIG_FILE" 2>/dev/null)" == "true" ]] && check_gcloud
    [[ "$(yq '.oauth.gh.enabled // false' "$CONFIG_FILE" 2>/dev/null)" == "true" ]] && check_gh
    [[ "$(yq '.oauth.az.enabled // false' "$CONFIG_FILE" 2>/dev/null)" == "true" ]] && check_az
else
    # No config - check whatever is installed
    check_gcloud
    check_gh
fi

if [[ $FAILURES -gt 0 ]]; then
    [[ "$QUIET" == false ]] && echo "$FAILURES tool(s) need re-authentication"
    exit 1
fi

[[ "$QUIET" == false ]] && echo "All OAuth tokens valid."
exit 0
