#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing para-llm-directory..."

# Check for fzf
if ! command -v fzf &> /dev/null; then
    echo "fzf not found. Installing via homebrew..."
    brew install fzf
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR/tmux-new-branch.sh"
chmod +x "$SCRIPT_DIR/tmux-cleanup-branch.sh"
chmod +x "$SCRIPT_DIR/envs.sh"
chmod +x "$SCRIPT_DIR/tmux-command-center.sh"
chmod +x "$SCRIPT_DIR/tmux-cc-hooks.sh"

# Make plugin scripts executable (including helper scripts)
if [[ -d "$SCRIPT_DIR/plugins/claude-state-monitor" ]]; then
    chmod +x "$SCRIPT_DIR/plugins/claude-state-monitor/"*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR/plugins/claude-state-monitor/hooks/"*.sh 2>/dev/null || true
fi

# Install Claude Code hooks for state monitoring
echo "Setting up Claude Code hooks for state monitoring..."

# Create hooks directory in user home
HOOKS_INSTALL_DIR="$HOME/.para-llm/plugins/claude-state-monitor/hooks"
mkdir -p "$HOOKS_INSTALL_DIR"

# Copy state-tracker script
cp "$SCRIPT_DIR/plugins/claude-state-monitor/hooks/state-tracker.sh" "$HOOKS_INSTALL_DIR/"
chmod +x "$HOOKS_INSTALL_DIR/state-tracker.sh"
echo "  Installed state-tracker.sh to $HOOKS_INSTALL_DIR"

# Merge hooks configuration into Claude settings
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOKS_CONFIG="$SCRIPT_DIR/plugins/claude-state-monitor/hooks/hooks-config.json"

if [[ -f "$HOOKS_CONFIG" ]]; then
    mkdir -p "$HOME/.claude"

    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        # Backup existing settings
        cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.backup"
        echo "  Backed up $CLAUDE_SETTINGS"

        # Check if jq is available
        if command -v jq &> /dev/null; then
            # Merge hooks into existing settings
            EXISTING_HOOKS=$(jq '.hooks // {}' "$CLAUDE_SETTINGS" 2>/dev/null || echo '{}')
            NEW_HOOKS=$(jq '.hooks' "$HOOKS_CONFIG")

            # Merge and write back
            jq --argjson new "$NEW_HOOKS" '.hooks = (.hooks // {}) + $new' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && \
                mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
            echo "  Merged hooks configuration into $CLAUDE_SETTINGS"
        else
            echo "  Warning: jq not found, cannot merge hooks automatically"
            echo "  Please manually add hooks from: $HOOKS_CONFIG"
            echo "  to your: $CLAUDE_SETTINGS"
        fi
    else
        # No existing settings, just copy the hooks config
        cp "$HOOKS_CONFIG" "$CLAUDE_SETTINGS"
        echo "  Created $CLAUDE_SETTINGS with hooks configuration"
    fi
fi

# Create envs directory
mkdir -p ~/code/envs

# Backup existing tmux.conf if it exists
if [[ -f ~/.tmux.conf ]]; then
    cp ~/.tmux.conf ~/.tmux.conf.backup
    echo "Backed up existing ~/.tmux.conf to ~/.tmux.conf.backup"
fi

# Remove existing para-llm-directory bindings if present
if grep -q "para-llm-directory" ~/.tmux.conf 2>/dev/null; then
    echo "Removing existing para-llm-directory bindings..."
    # Remove the block from "# para-llm-directory" through "synchronize-panes" line
    sed -i.tmp '/# para-llm-directory bindings/,/synchronize-panes/d' ~/.tmux.conf
    rm -f ~/.tmux.conf.tmp
    # Clean up any trailing blank lines
    sed -i.tmp -e :a -e '/^\n*$/{$d;N;ba' -e '}' ~/.tmux.conf 2>/dev/null || true
    rm -f ~/.tmux.conf.tmp
fi

# Add bindings to tmux.conf (always fresh)
echo "Adding bindings pointing to: $SCRIPT_DIR"
cat >> ~/.tmux.conf << EOF

# para-llm-directory bindings
# Ctrl+b c: interactive project + branch selection, creates clone in envs/
bind-key c display-popup -E -w 60% -h 60% "$SCRIPT_DIR/tmux-new-branch.sh"

# Ctrl+b k: cleanup/delete a feature branch environment
bind-key k display-popup -E -w 60% -h 60% "$SCRIPT_DIR/tmux-cleanup-branch.sh"

# Ctrl+b C: original behavior (plain new window)
bind-key C new-window -c "#{pane_current_path}"

# Ctrl+b v: Command Center (tiled view of all env windows)
bind-key v run-shell "$SCRIPT_DIR/tmux-command-center.sh"

# Ctrl+b b: Toggle broadcast mode (type in all panes at once)
bind-key b set-window-option synchronize-panes \; display-message "Toggled broadcast mode"
EOF
echo "Added bindings to ~/.tmux.conf"

# Reload tmux config if tmux is running
if tmux list-sessions &> /dev/null; then
    tmux source-file ~/.tmux.conf
    echo "Reloaded tmux config - bindings updated in place"
fi

echo ""
echo "✓ Installation complete!"
echo ""
echo "Scripts now at:"
echo "  $SCRIPT_DIR"
echo ""
echo "Keybindings:"
echo "  Ctrl+b c  - Create/resume feature branch"
echo "  Ctrl+b k  - Cleanup feature branch"
echo "  Ctrl+b v  - Command Center (tiled view of all envs)"
echo "  Ctrl+b b  - Toggle broadcast mode (type in all panes)"
echo "  Ctrl+b C  - Plain new window"
echo ""
echo "Optional: Add this alias to your ~/.zshrc or ~/.bashrc:"
echo "  alias envs='$SCRIPT_DIR/envs.sh'"
