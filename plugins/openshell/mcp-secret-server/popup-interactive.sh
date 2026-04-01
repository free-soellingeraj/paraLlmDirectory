#!/usr/bin/env bash
# popup-interactive.sh - Tmux popup for running interactive commands
# Launched by the MCP server when Claude calls run_interactive
# Runs a command in a full interactive shell, captures exit code.
#
# Arguments:
#   $1 - Command to run
#   $2 - Reason (displayed to user)
#   $3 - Result file path (where to write the outcome)

set -u

# Source user profile for PATH
if [[ -f "$HOME/.bashrc" ]]; then
    source "$HOME/.bashrc" 2>/dev/null || true
elif [[ -f "$HOME/.bash_profile" ]]; then
    source "$HOME/.bash_profile" 2>/dev/null || true
elif [[ -f "$HOME/.profile" ]]; then
    source "$HOME/.profile" 2>/dev/null || true
fi

COMMAND="${1:-}"
REASON="${2:-}"
RESULT_FILE="${3:-}"

if [[ -z "$COMMAND" || -z "$RESULT_FILE" ]]; then
    echo "Usage: popup-interactive.sh <command> <reason> <result-file>"
    exit 1
fi

echo ""
echo "Interactive Session"
echo "==================="
echo ""
if [[ -n "$REASON" ]]; then
    echo "  $REASON"
    echo ""
fi
echo "  Running: $COMMAND"
echo "  (Complete the interactive flow, then this window will close)"
echo ""
echo "---"
echo ""

# Run the command in an interactive subshell
eval "$COMMAND"
exit_code=$?

echo ""
echo "---"

if [[ $exit_code -eq 0 ]]; then
    echo "  Command completed successfully."
    cat > "$RESULT_FILE" << EOF
{"success":true,"exit_code":0,"message":"Interactive command completed successfully"}
EOF
else
    echo "  Command exited with code $exit_code."
    cat > "$RESULT_FILE" << EOF
{"success":false,"exit_code":$exit_code,"message":"Interactive command exited with code $exit_code"}
EOF
fi

echo ""
read -r -p "  Press Enter to close..."
