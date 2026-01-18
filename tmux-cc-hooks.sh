#!/bin/bash

# Command Center Hooks - Handle dynamic window/pane changes
# Called by tmux hooks when command center is active

COMMAND_CENTER="command-center"
ACTION="$1"

# Check if command center exists
cc_exists() {
    tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qx "$COMMAND_CENTER"
}

# Remove all command center hooks
cleanup_hooks() {
    tmux set-hook -gu after-new-window 2>/dev/null
    tmux set-hook -gu pane-exited 2>/dev/null
    tmux set-hook -gu window-unlinked 2>/dev/null
}

# Check if command center was destroyed and clean up hooks
handle_window_unlinked() {
    if ! cc_exists; then
        cleanup_hooks
    fi
}

# Handle new window creation - join it to command center
handle_new_window() {
    if ! cc_exists; then
        return
    fi

    # Get the newly created window's info
    local new_window_name new_pane_id
    new_window_name=$(tmux display-message -p '#{window_name}')
    new_pane_id=$(tmux display-message -p '#{pane_id}')

    # Don't process if this IS the command center
    if [[ "$new_window_name" == "$COMMAND_CENTER" ]]; then
        return
    fi

    # Join the new pane into command center
    tmux join-pane -s "$new_pane_id" -t "$COMMAND_CENTER" -h

    # Reapply tiled layout
    tmux select-layout -t "$COMMAND_CENTER" tiled

    # Set the pane title to the window name
    local pane_count last_pane_index
    pane_count=$(tmux list-panes -t "$COMMAND_CENTER" 2>/dev/null | wc -l | tr -d ' ')
    last_pane_index=$((pane_count - 1))
    tmux select-pane -t "$COMMAND_CENTER.$last_pane_index" -T "$new_window_name"

    # Switch to command center
    tmux select-window -t "$COMMAND_CENTER"
}

# Handle pane exit - reapply layout
handle_pane_exited() {
    if ! cc_exists; then
        return
    fi

    # Check if we're in the command center window
    local current_window
    current_window=$(tmux display-message -p '#{window_name}')

    if [[ "$current_window" == "$COMMAND_CENTER" ]]; then
        # Small delay to let tmux finish removing the pane
        sleep 0.1

        # Check if there are still panes in command center
        local pane_count
        pane_count=$(tmux list-panes -t "$COMMAND_CENTER" 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$pane_count" -gt 0 ]]; then
            # Reapply tiled layout
            tmux select-layout -t "$COMMAND_CENTER" tiled
        fi
    fi
}

case "$ACTION" in
    new-window)
        handle_new_window
        ;;
    pane-exited)
        handle_pane_exited
        ;;
    window-unlinked)
        handle_window_unlinked
        ;;
esac
