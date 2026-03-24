#!/usr/bin/env bash
# openshell-manage.sh - fzf-based management menu for OpenShell sandboxes
# Launched via Ctrl+b o (tmux display-popup)

# Source user profile for PATH (fzf may be installed in ~/.fzf/bin)
# tmux display-popup runs non-interactive shell, so .bashrc isn't loaded
# NOTE: set -u must come AFTER sourcing, as bashrc may reference unset variables
if [[ -f "$HOME/.bashrc" ]]; then
    source "$HOME/.bashrc" 2>/dev/null || true
elif [[ -f "$HOME/.bash_profile" ]]; then
    source "$HOME/.bash_profile" 2>/dev/null || true
elif [[ -f "$HOME/.profile" ]]; then
    source "$HOME/.profile" 2>/dev/null || true
fi

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    echo "para-llm: No bootstrap file found"
    exit 1
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"

# Source config
if [[ -f "$PARA_LLM_ROOT/config" ]]; then
    source "$PARA_LLM_ROOT/config"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/openshell-sandbox.sh"
source "$SCRIPT_DIR/openshell-secrets.sh"

SANDBOX_STATE_DIR="$PARA_LLM_ROOT/openshell/state/sandboxes"
mkdir -p "$SANDBOX_STATE_DIR"

# --- Helper ---

# Read a line of input with Escape-to-go-back support
read_input() {
    local prompt="$1"
    local default="${2:-}"
    REPLY=""

    printf "%s" "$prompt"

    while true; do
        IFS= read -r -s -n 1 ch

        # Escape key
        if [[ "$ch" == $'\e' ]]; then
            read -r -s -n 2 -t 0.1 _ 2>/dev/null || true
            echo ""
            return 1
        fi

        # Enter key
        if [[ "$ch" == "" ]]; then
            echo ""
            if [[ -z "$REPLY" && -n "$default" ]]; then
                REPLY="$default"
            fi
            return 0
        fi

        # Backspace
        if [[ "$ch" == $'\177' || "$ch" == $'\b' ]]; then
            if [[ -n "$REPLY" ]]; then
                REPLY="${REPLY%?}"
                printf '\b \b'
            fi
            continue
        fi

        REPLY+="$ch"
        printf "%s" "$ch"
    done
}

# --- Menu actions ---

action_list() {
    echo ""
    echo "Active Sandboxes"
    echo "================"

    local found=false
    for state_file in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$state_file" ]] || continue
        found=true
        local name project branch
        name=$(basename "$state_file")
        project=$(grep "^PROJECT=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        branch=$(grep "^BRANCH=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')

        local status="unknown"
        if openshell_available && openshell sandbox get "$name" &>/dev/null 2>&1; then
            status="running"
        else
            status="stopped"
        fi

        echo "  $name ($project/$branch) [$status]"
    done

    if [[ "$found" == false ]]; then
        echo "  No active sandboxes."
    fi
    echo ""
    read -r -p "Press Enter to continue..."
}

action_connect() {
    local sandboxes=()
    for state_file in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$state_file" ]] || continue
        local name project branch
        name=$(basename "$state_file")
        project=$(grep "^PROJECT=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        branch=$(grep "^BRANCH=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        sandboxes+=("$name ($project/$branch)")
    done

    if [[ ${#sandboxes[@]} -eq 0 ]]; then
        echo "No active sandboxes."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    local selected
    selected=$(printf "%s\n← Back" "${sandboxes[@]}" | fzf --prompt="Connect to: " --height=10 --no-info)
    [[ -z "$selected" || "$selected" == "← Back" ]] && return

    local name="${selected%% *}"
    openshell sandbox connect "$name"
}

action_destroy() {
    local sandboxes=()
    for state_file in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$state_file" ]] || continue
        local name project branch
        name=$(basename "$state_file")
        project=$(grep "^PROJECT=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        branch=$(grep "^BRANCH=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        sandboxes+=("$name ($project/$branch)")
    done

    if [[ ${#sandboxes[@]} -eq 0 ]]; then
        echo "No active sandboxes."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    local selected
    selected=$(printf "%s\n← Back" "${sandboxes[@]}" | fzf --prompt="Destroy sandbox: " --height=10 --no-info)
    [[ -z "$selected" || "$selected" == "← Back" ]] && return

    local name="${selected%% *}"

    read -r -p "Destroy sandbox '$name'? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy] ]]; then
        local state_file="$SANDBOX_STATE_DIR/$name"
        local project branch
        project=$(grep "^PROJECT=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        branch=$(grep "^BRANCH=" "$state_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"')
        sandbox_destroy "$project" "$branch"
        echo "Sandbox '$name' destroyed."
    fi
}

action_logs() {
    local sandboxes=()
    for state_file in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$state_file" ]] || continue
        local name
        name=$(basename "$state_file")
        sandboxes+=("$name")
    done

    if [[ ${#sandboxes[@]} -eq 0 ]]; then
        echo "No active sandboxes."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    local selected
    selected=$(printf "%s\n← Back" "${sandboxes[@]}" | fzf --prompt="View logs for: " --height=10 --no-info)
    [[ -z "$selected" || "$selected" == "← Back" ]] && return

    echo ""
    echo "Logs for '$selected' (Ctrl+C to stop):"
    echo ""
    openshell logs "$selected" --tail --source sandbox 2>&1 || {
        echo "Failed to retrieve logs."
    }
    read -r -p "Press Enter to continue..."
}

action_manage_secrets() {
    while true; do
        echo ""
        echo "Manage Secrets"
        echo "=============="
        local names
        names=$(secret_list)
        if [[ -n "$names" ]]; then
            echo "Registered secrets:"
            while IFS= read -r name; do
                [[ -z "$name" ]] && continue
                echo "  - $name"
            done <<< "$names"
        else
            echo "No secrets registered."
        fi
        echo ""

        local action
        action=$(printf "Add secret\nRemove secret\n← Back" | fzf --prompt="Action: " --height=6 --no-info)

        case "$action" in
            "Add secret")
                echo ""
                read_input "Secret name: " || continue
                local secret_name="$REPLY"
                [[ -z "$secret_name" ]] && continue

                printf "Value: "
                secret_value=""
                while true; do
                    IFS= read -r -s -n 1 ch
                    if [[ "$ch" == "" ]]; then
                        echo ""
                        break
                    fi
                    if [[ "$ch" == $'\177' || "$ch" == $'\b' ]]; then
                        if [[ -n "$secret_value" ]]; then
                            secret_value="${secret_value%?}"
                            printf '\b \b'
                        fi
                        continue
                    fi
                    secret_value+="$ch"
                    printf '*'
                done
                [[ -z "$secret_value" ]] && { echo "Cancelled."; continue; }

                local scope
                scope=$(printf "All projects (global)\n← Back" | fzf --prompt="Scope: " --height=5 --no-info)
                case "$scope" in
                    "All projects (global)")
                        secret_store "$secret_name" "$secret_value" "global"
                        echo "Secret '$secret_name' registered globally."
                        ;;
                    *) continue ;;
                esac
                secret_value=""
                ;;
            "Remove secret")
                if [[ -z "$names" ]]; then
                    echo "Nothing to remove."
                    continue
                fi
                local selected
                selected=$(printf "%s\n← Back" "$names" | fzf --prompt="Remove: " --height=10 --no-info)
                [[ -z "$selected" || "$selected" == "← Back" ]] && continue
                secret_remove "$selected" "global"
                echo "Secret '$selected' removed."
                ;;
            *) return ;;
        esac
    done
}

action_update_policy() {
    local sandboxes=()
    for state_file in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$state_file" ]] || continue
        local name
        name=$(basename "$state_file")
        sandboxes+=("$name")
    done

    if [[ ${#sandboxes[@]} -eq 0 ]]; then
        echo "No active sandboxes."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    local selected
    selected=$(printf "%s\n← Back" "${sandboxes[@]}" | fzf --prompt="Update policy for: " --height=10 --no-info)
    [[ -z "$selected" || "$selected" == "← Back" ]] && return

    echo ""
    echo "Current policy can be retrieved with:"
    echo "  openshell policy get $selected --full"
    echo ""
    read_input "Path to new policy YAML: " || return
    local policy_path="$REPLY"

    if [[ ! -f "$policy_path" ]]; then
        echo "File not found: $policy_path"
        return
    fi

    echo "Updating policy for '$selected'..."
    openshell policy set "$selected" --policy "$policy_path" --wait 2>&1
    echo "Done."
    read -r -p "Press Enter to continue..."
}

action_gateway_status() {
    echo ""
    echo "Gateway Status"
    echo "=============="
    if ! openshell_available; then
        echo "  openshell CLI: NOT INSTALLED"
        echo "  Install with: uv tool install -U openshell"
    else
        echo "  openshell CLI: installed"
        local status
        status=$(gateway_status)
        echo "  Gateway: $status"
    fi

    if ! docker_available; then
        echo "  Docker: NOT RUNNING"
    else
        echo "  Docker: running"
    fi
    echo ""
    read -r -p "Press Enter to continue..."
}

action_toggle_auto() {
    local current="${OPENSHELL_AUTO_SANDBOX:-0}"
    local new_state
    if [[ "$current" == "1" ]]; then
        new_state="0"
        echo "Auto-sandbox: DISABLED (will ask for each new env)"
    else
        new_state="1"
        echo "Auto-sandbox: ENABLED (all new envs will be sandboxed)"
    fi

    # Update config file
    if grep -q "^OPENSHELL_AUTO_SANDBOX=" "$PARA_LLM_ROOT/config" 2>/dev/null; then
        sed -i.tmp "s/^OPENSHELL_AUTO_SANDBOX=.*/OPENSHELL_AUTO_SANDBOX=$new_state/" "$PARA_LLM_ROOT/config"
        rm -f "$PARA_LLM_ROOT/config.tmp"
    else
        echo "" >> "$PARA_LLM_ROOT/config"
        echo "OPENSHELL_AUTO_SANDBOX=$new_state" >> "$PARA_LLM_ROOT/config"
    fi
}

# --- Main menu ---

while true; do
    echo ""
    echo "Para-LLM OpenShell Management"
    echo "=============================="

    # Count active sandboxes
    local count=0
    for f in "$SANDBOX_STATE_DIR"/*; do
        [[ -f "$f" ]] && (( count++ ))
    done

    local gw_status="unknown"
    if openshell_available; then
        gw_status=$(gateway_status)
    else
        gw_status="not installed"
    fi

    echo "Sandboxes: ${count} active | Gateway: ${gw_status}"
    echo "Auto-sandbox: ${OPENSHELL_AUTO_SANDBOX:-0}"
    echo ""

    # Dynamic toggle label
    local toggle_label
    if [[ "${OPENSHELL_AUTO_SANDBOX:-0}" == "1" ]]; then
        toggle_label="Disable auto-sandbox"
    else
        toggle_label="Enable auto-sandbox"
    fi

    ACTION=$(printf "List sandboxes\nConnect to sandbox\nDestroy sandbox\nView sandbox logs\nManage secrets\nUpdate policy\nGateway status\n%s\nExit" "$toggle_label" | \
        fzf --prompt="Action: " --height=13 --no-info)

    case "$ACTION" in
        "List sandboxes")       action_list ;;
        "Connect to sandbox")   action_connect ;;
        "Destroy sandbox")      action_destroy ;;
        "View sandbox logs")    action_logs ;;
        "Manage secrets")       action_manage_secrets ;;
        "Update policy")        action_update_policy ;;
        "Gateway status")       action_gateway_status ;;
        "Enable auto-sandbox"|"Disable auto-sandbox") action_toggle_auto ;;
        "Exit"|"")              exit 0 ;;
    esac

    # Re-source config in case toggle changed it
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
done
