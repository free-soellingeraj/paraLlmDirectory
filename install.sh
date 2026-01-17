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
chmod +x "$SCRIPT_DIR/pane-monitor.sh"

# Create envs directory
mkdir -p ~/code/envs

# Backup existing tmux.conf if it exists
if [[ -f ~/.tmux.conf ]]; then
    cp ~/.tmux.conf ~/.tmux.conf.backup
    echo "Backed up existing ~/.tmux.conf to ~/.tmux.conf.backup"
fi

# Check if bindings already exist
if grep -q "para-llm-directory" ~/.tmux.conf 2>/dev/null; then
    echo "Bindings already exist in ~/.tmux.conf"
else
    # Append bindings to tmux.conf
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
fi

# Reload tmux config if tmux is running
if tmux list-sessions &> /dev/null; then
    tmux source-file ~/.tmux.conf
    echo "Reloaded tmux config"
fi

echo ""
echo "✓ Installation complete!"
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
