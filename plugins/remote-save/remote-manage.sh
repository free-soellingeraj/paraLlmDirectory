#!/usr/bin/env bash
# remote-manage.sh - fzf-based menu for managing remote save backends
# Launched via Ctrl+b t (tmux display-popup)

set -u

# Read PARA_LLM_ROOT from bootstrap pointer
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    echo "para-llm: No bootstrap file found"
    exit 1
fi
PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
REMOTES_DIR="$PARA_LLM_ROOT/remotes"
ACTIVE_FILE="$REMOTES_DIR/.active"

# Source config
if [[ -f "$PARA_LLM_ROOT/config" ]]; then
    source "$PARA_LLM_ROOT/config"
fi

mkdir -p "$REMOTES_DIR"

# --- Helper functions ---

get_active_remote() {
    if [[ -f "$ACTIVE_FILE" ]]; then
        cat "$ACTIVE_FILE"
    else
        echo ""
    fi
}

list_remotes() {
    local active
    active=$(get_active_remote)
    for f in "$REMOTES_DIR"/*; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f")
        [[ "$name" == ".active" ]] && continue
        if [[ "$name" == "$active" ]]; then
            echo "* $name"
        else
            echo "  $name"
        fi
    done
}

load_remote() {
    local name="$1"
    local remote_file="$REMOTES_DIR/$name"
    if [[ -f "$remote_file" ]]; then
        source "$remote_file"
    fi
}

# --- Menu actions ---

action_add() {
    local REMOTE_BACKEND="ssh"
    local REMOTE_NAME=""
    local REMOTE_HOST=""
    local REMOTE_SSH_KEY=""
    local REMOTE_SSH_PORT=""
    local REMOTE_DIR=""
    local SOURCE=""
    local step=1

    while true; do
        case $step in
            1)
                # Step 1: Remote name
                echo ""
                echo "Add new remote"
                echo "=============="
                echo ""
                read -r -p "Remote name (e.g., my-server) [← empty to go back]: " REMOTE_NAME
                [[ -z "$REMOTE_NAME" ]] && return
                # Sanitize
                REMOTE_NAME=$(echo "$REMOTE_NAME" | sed 's/[^a-zA-Z0-9_-]//g')
                if [[ -z "$REMOTE_NAME" ]]; then
                    echo "Invalid name."
                    continue
                fi
                if [[ -f "$REMOTES_DIR/$REMOTE_NAME" ]]; then
                    echo "Remote '$REMOTE_NAME' already exists."
                    continue
                fi
                step=2
                ;;
            2)
                # Step 2: Connection type
                # Check for SSH config hosts
                local SSH_HOSTS=""
                if [[ -f "$HOME/.ssh/config" ]]; then
                    SSH_HOSTS=$(awk '/^Host / && !/\*/ { print $2 }' "$HOME/.ssh/config" 2>/dev/null)
                fi

                local sources=""
                if [[ -n "$SSH_HOSTS" ]]; then
                    sources="SSH config host"
                fi
                sources="${sources:+$sources\n}Reverse tunnel (ssh -R)\nEnter manually\n← Back"

                echo ""
                SOURCE=$(printf "%b" "$sources" | fzf --prompt="Connection type: " --height=10 --no-info)
                if [[ -z "$SOURCE" || "$SOURCE" == "← Back" ]]; then
                    step=1; continue
                fi

                # Reset connection fields for fresh selection
                REMOTE_HOST=""
                REMOTE_SSH_KEY=""
                REMOTE_SSH_PORT=""

                case "$SOURCE" in
                    "SSH config host")
                        step=3
                        ;;
                    "Reverse tunnel (ssh -R)")
                        step=4
                        ;;
                    "Enter manually")
                        step=5
                        ;;
                esac
                ;;
            3)
                # Step 3: SSH config host selection
                echo ""
                local SELECTED
                SELECTED=$(printf "%s\n← Back" "$SSH_HOSTS" | fzf --prompt="SSH host: " --height=15)
                if [[ -z "$SELECTED" || "$SELECTED" == "← Back" ]]; then
                    step=2; continue
                fi

                # Resolve user, hostname, port, and identity file from ssh config
                local ssh_resolved
                ssh_resolved=$(ssh -G "$SELECTED" 2>/dev/null)
                local SSH_USER SSH_HOSTNAME SSH_PORT SSH_IDENTITY
                SSH_USER=$(echo "$ssh_resolved" | awk '/^user / { print $2 }')
                SSH_HOSTNAME=$(echo "$ssh_resolved" | awk '/^hostname / { print $2 }')
                SSH_PORT=$(echo "$ssh_resolved" | awk '/^port / { print $2 }')
                SSH_IDENTITY=$(echo "$ssh_resolved" | awk '/^identityfile / { print $2; exit }')

                if [[ -n "$SSH_USER" && "$SSH_USER" != "$(whoami)" ]]; then
                    REMOTE_HOST="${SSH_USER}@${SSH_HOSTNAME:-$SELECTED}"
                else
                    REMOTE_HOST="${SSH_HOSTNAME:-$SELECTED}"
                fi

                if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
                    REMOTE_SSH_PORT="$SSH_PORT"
                fi

                if [[ -n "$SSH_IDENTITY" ]]; then
                    SSH_IDENTITY="${SSH_IDENTITY/#\~/$HOME}"
                    if [[ -f "$SSH_IDENTITY" ]]; then
                        REMOTE_SSH_KEY="$SSH_IDENTITY"
                    fi
                fi

                echo "  Host: $REMOTE_HOST"
                [[ -n "$REMOTE_SSH_PORT" ]] && echo "  Port: $REMOTE_SSH_PORT"
                [[ -n "$REMOTE_SSH_KEY" ]] && echo "  Key: $REMOTE_SSH_KEY"
                step=6
                ;;
            4)
                # Step 4: Reverse tunnel
                echo ""

                # Check if we're in an SSH session
                if [[ -z "${SSH_CONNECTION:-}" && -z "${SSH_CLIENT:-}" ]]; then
                    echo "Not in an SSH session."
                    echo ""
                    echo "Reverse tunnels require you to be SSH'd into this machine."
                    echo "From your local machine, connect with:"
                    echo "  ssh -R <port>:localhost:22 <this-host>"
                    echo ""
                    read -r -p "Press Enter to go back..."
                    step=2; continue
                fi

                # Detect active reverse tunnels
                local REVERSE_TUNNELS=""
                if command -v lsof &>/dev/null; then
                    REVERSE_TUNNELS=$(lsof -i -n -P 2>/dev/null | grep "sshd" | grep "LISTEN" | \
                        awk '{ print $9 }' | sed 's/.*://' | sort -un | grep -v "^22$")
                elif command -v ss &>/dev/null; then
                    REVERSE_TUNNELS=$(ss -tlnp 2>/dev/null | grep "sshd" | \
                        awk '{ print $4 }' | sed 's/.*://' | sort -un | grep -v "^22$")
                fi

                if [[ -z "$REVERSE_TUNNELS" ]]; then
                    local CLIENT_IP="${SSH_CONNECTION%% *}"
                    echo "SSH session detected (from $CLIENT_IP), but no reverse tunnels found."
                    echo ""
                    echo "Your SSH session was not started with a reverse port forward."
                    echo "Reconnect with:"
                    echo "  ssh -R <port>:localhost:22 <this-host>"
                    echo ""
                    echo "Example:"
                    echo "  ssh -R 2222:localhost:22 $(whoami)@$(hostname)"
                    echo ""
                    read -r -p "Press Enter to go back..."
                    step=2; continue
                fi

                # Pick tunnel port
                echo "Detected reverse tunnel ports:"
                local TUNNEL_PORT
                TUNNEL_PORT=$(printf "%s\n← Back" "$REVERSE_TUNNELS" | fzf --prompt="Select tunnel port: " --height=10)
                if [[ -z "$TUNNEL_PORT" || "$TUNNEL_PORT" == "← Back" ]]; then
                    step=2; continue
                fi

                REMOTE_HOST="localhost"
                REMOTE_SSH_PORT="$TUNNEL_PORT"

                read -r -p "Username on originating machine [$(whoami)] [← empty to go back]: " TUNNEL_USER
                if [[ "$TUNNEL_USER" == "" ]]; then
                    # Empty means accept default, not go back - use a sentinel
                    TUNNEL_USER="$(whoami)"
                fi
                if [[ "$TUNNEL_USER" != "$(whoami)" ]]; then
                    REMOTE_HOST="${TUNNEL_USER}@localhost"
                fi

                echo "  Using: ssh -p $REMOTE_SSH_PORT $REMOTE_HOST"
                step=6
                ;;
            5)
                # Step 5: Manual entry
                echo ""
                read -r -p "SSH host (e.g., user@host) [← empty to go back]: " REMOTE_HOST
                if [[ -z "$REMOTE_HOST" ]]; then
                    step=2; continue
                fi

                read -r -p "SSH port [22]: " REMOTE_SSH_PORT
                REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-}"
                [[ "$REMOTE_SSH_PORT" == "22" ]] && REMOTE_SSH_PORT=""

                read -r -p "SSH key path (optional, leave empty for default): " REMOTE_SSH_KEY
                step=6
                ;;
            6)
                # Step 6: Remote directory
                local REMOTE_USER="${REMOTE_HOST%%@*}"
                if [[ "$REMOTE_USER" == "$REMOTE_HOST" ]]; then
                    REMOTE_USER="$(whoami)"
                fi

                echo ""
                read -r -p "Remote directory [/home/${REMOTE_USER}/.para-llm-remote] [← 'back' to go back]: " REMOTE_DIR
                if [[ "$REMOTE_DIR" == "back" ]]; then
                    REMOTE_DIR=""
                    # Go back to the connection type step
                    step=2; continue
                fi
                REMOTE_DIR="${REMOTE_DIR:-/home/${REMOTE_USER}/.para-llm-remote}"
                step=7
                ;;
            7)
                # Step 7: Confirm and save
                echo ""
                echo "Remote configuration:"
                echo "  Name:      $REMOTE_NAME"
                echo "  Host:      $REMOTE_HOST"
                [[ -n "$REMOTE_SSH_PORT" ]] && echo "  Port:      $REMOTE_SSH_PORT"
                [[ -n "$REMOTE_SSH_KEY" ]] && echo "  Key:       $REMOTE_SSH_KEY"
                echo "  Directory: $REMOTE_DIR"
                echo ""

                local confirm
                confirm=$(printf "Save\n← Back\nCancel" | fzf --prompt="Confirm: " --height=5 --no-info)
                case "$confirm" in
                    "Save")
                        ;;
                    "← Back")
                        step=6; continue
                        ;;
                    *)
                        return
                        ;;
                esac

                # Write remote config file
                cat > "$REMOTES_DIR/$REMOTE_NAME" << REMOTE_EOF
# para-llm remote: $REMOTE_NAME
REMOTE_BACKEND="$REMOTE_BACKEND"
REMOTE_HOST="$REMOTE_HOST"
REMOTE_DIR="$REMOTE_DIR"
REMOTE_SSH_KEY="${REMOTE_SSH_KEY:-}"
REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-}"
REMOTE_EOF

                echo ""
                echo "Remote '$REMOTE_NAME' created."

                # Set as active if it's the only one
                local count
                count=$(list_remotes | wc -l | tr -d ' ')
                if [[ "$count" -eq 1 ]]; then
                    echo "$REMOTE_NAME" > "$ACTIVE_FILE"
                    echo "Set as active remote."
                fi

                # Offer to test
                read -r -p "Test connection now? [Y/n]: " test_choice
                if [[ ! "$test_choice" =~ ^[Nn] ]]; then
                    action_test "$REMOTE_NAME"
                fi
                return
                ;;
        esac
    done
}

action_remove() {
    local remotes
    remotes=$(list_remotes)
    if [[ -z "$remotes" ]]; then
        echo "No remotes configured."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "Remove remote"
    echo "============="
    local selected
    selected=$(printf "%s\n← Back" "$remotes" | fzf --prompt="Select remote to remove: " --height=10)
    [[ -z "$selected" || "$selected" == "← Back" ]] && return

    # Strip leading marker
    local name
    name=$(echo "$selected" | sed 's/^[* ] //')

    read -r -p "Remove remote '$name'? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy] ]]; then
        rm -f "$REMOTES_DIR/$name"
        # Clear active if this was the active remote
        if [[ "$(get_active_remote)" == "$name" ]]; then
            rm -f "$ACTIVE_FILE"
        fi
        echo "Remote '$name' removed."
    fi
}

action_select() {
    local remotes
    remotes=$(list_remotes)
    if [[ -z "$remotes" ]]; then
        echo "No remotes configured."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "Select active remote"
    echo "===================="
    local selected
    selected=$(printf "%s\n← Back" "$remotes" | fzf --prompt="Select active remote: " --height=10)
    [[ -z "$selected" || "$selected" == "← Back" ]] && return

    local name
    name=$(echo "$selected" | sed 's/^[* ] //')
    echo "$name" > "$ACTIVE_FILE"
    echo "Active remote set to '$name'."
}

action_test() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        local remotes
        remotes=$(list_remotes)
        if [[ -z "$remotes" ]]; then
            echo "No remotes configured."
            read -r -p "Press Enter to continue..."
            return
        fi

        echo ""
        local selected
        selected=$(printf "%s\n← Back" "$remotes" | fzf --prompt="Select remote to test: " --height=10)
        [[ -z "$selected" || "$selected" == "← Back" ]] && return
        name=$(echo "$selected" | sed 's/^[* ] //')
    fi

    echo ""
    echo "Testing remote '$name'..."
    load_remote "$name"

    # Find and source the backend
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local backend_file="$SCRIPT_DIR/backends/${REMOTE_BACKEND}.sh"
    if [[ ! -f "$backend_file" ]]; then
        echo "ERROR: Backend '${REMOTE_BACKEND}' not found at $backend_file"
        return 1
    fi
    source "$backend_file"

    if backend_test; then
        echo "Connection successful!"
    else
        echo "Connection FAILED."
    fi
}

action_toggle() {
    local current="${REMOTE_SAVE_ENABLED:-1}"
    local new_state
    if [[ "$current" == "1" ]]; then
        new_state="0"
        echo "Automatic updates: DISABLED"
    else
        # Check we have an active remote
        local active
        active=$(get_active_remote)
        if [[ -z "$active" ]]; then
            echo "No active remote configured. Add a remote first."
            read -r -p "Press Enter to continue..."
            return
        fi
        new_state="1"
        echo "Automatic updates: ENABLED (using '$active')"
    fi

    # Update config file
    if grep -q "^REMOTE_SAVE_ENABLED=" "$PARA_LLM_ROOT/config" 2>/dev/null; then
        sed -i.tmp "s/^REMOTE_SAVE_ENABLED=.*/REMOTE_SAVE_ENABLED=$new_state/" "$PARA_LLM_ROOT/config"
        rm -f "$PARA_LLM_ROOT/config.tmp"
    else
        echo "" >> "$PARA_LLM_ROOT/config"
        echo "# Remote save (push state to remote on each save cycle)" >> "$PARA_LLM_ROOT/config"
        echo "REMOTE_SAVE_ENABLED=$new_state" >> "$PARA_LLM_ROOT/config"
    fi
}

# --- Main menu ---

while true; do
    echo ""
    echo "Para-LLM Remote Management"
    echo "=========================="

    active=$(get_active_remote)
    status="${REMOTE_SAVE_ENABLED:-1}"
    if [[ "$status" == "1" ]]; then
        echo "Auto-updates: ON | Active: ${active:-none}"
    else
        echo "Auto-updates: OFF | Active: ${active:-none}"
    fi

    echo ""
    remotes=$(list_remotes)
    if [[ -n "$remotes" ]]; then
        echo "Configured remotes:"
        echo "$remotes"
    else
        echo "No remotes configured."
    fi
    echo ""

    # Dynamic label for toggle
    if [[ "$status" == "1" ]]; then
        toggle_label="Disable automatic updates"
    else
        toggle_label="Enable automatic updates"
    fi

    ACTION=$(printf "Add remote\nRemove remote\nSelect active\nTest connection\n%s\nExit" "$toggle_label" | \
        fzf --prompt="Action: " --height=10 --no-info)

    case "$ACTION" in
        "Add remote")       action_add ;;
        "Remove remote")    action_remove ;;
        "Select active")    action_select ;;
        "Test connection")  action_test ;;
        "Enable automatic updates"|"Disable automatic updates") action_toggle ;;
        "Exit"|"")          exit 0 ;;
    esac

    # Re-source config in case toggle changed it
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
done
