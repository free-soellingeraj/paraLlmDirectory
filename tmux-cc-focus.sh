#!/usr/bin/env bash
# tmux-cc-focus.sh — "active agent gets more room" for the command-center.
#
# The command-center tiles every agent, so with 6-7 panes each tile is short and
# Claude Code's input box (rendered at the bottom of the pane) gets clipped — you
# lose sight of what you're typing. This promotes whichever pane you FOCUS into a
# large "main" pane (main-vertical: big on the left, the rest as compact strips
# you can still glance at), so the pane you're typing in is always full height.
#
# Wiring: a global `pane-focus-in` hook calls `promote`; it self-guards to the
# command-center window, so other windows are untouched.
#
#   tmux-cc-focus.sh enable         # apply the layout now + install the hook
#   tmux-cc-focus.sh disable        # remove the hook (layout left as-is)
#   tmux-cc-focus.sh promote <wid> <pid>   # (hook target) promote focused pane
set -uo pipefail

CC="command-center"
MAIN_WIDTH="${PARA_CC_MAIN_WIDTH:-60%}"   # width of the big/active pane
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Is this window the command-center? (accepts a window id/target)
is_cc() {
    [[ "$(tmux display-message -pt "$1" '#{window_name}' 2>/dev/null)" == "$CC" ]]
}

promote() {
    local wid="${1:-}" pid="${2:-}"
    [[ -n "$wid" ]] || wid="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    is_cc "$wid" || return 0
    # Respect a manual full-zoom (Ctrl+b z) — don't fight the user.
    [[ "$(tmux display-message -pt "$wid" '#{window_zoomed_flag}' 2>/dev/null)" == "1" ]] && return 0
    # Re-entrancy guard: our own swap/select-layout must not recurse into a loop.
    [[ "$(tmux show-option -gqv @cc_promoting 2>/dev/null)" == "1" ]] && return 0

    local n main active
    n="$(tmux list-panes -t "$wid" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${n:-0}" -lt 2 ]] && return 0
    active="${pid:-$(tmux display-message -pt "$wid" '#{pane_id}' 2>/dev/null)}"
    main="$(tmux list-panes -t "$wid" -F '#{pane_id}' 2>/dev/null | head -1)"   # index 0 = main slot
    [[ -z "$active" || -z "$main" ]] && return 0
    # Already the main pane -> nothing to do (and this is what stops any focus
    # event our own re-layout might emit from looping).
    [[ "$active" == "$main" ]] && return 0

    tmux set-option -g @cc_promoting 1 2>/dev/null || true
    trap 'tmux set-option -g @cc_promoting 0 2>/dev/null || true' RETURN
    # -d: keep the focused pane focused (it just moves into the main slot); no
    # active-pane change means no fresh pane-focus-in, so no recursion.
    tmux swap-pane -d -s "$active" -t "$main" 2>/dev/null || return 0
    tmux set-window-option -t "$wid" main-pane-width "$MAIN_WIDTH" 2>/dev/null || true
    tmux select-layout -t "$wid" main-vertical 2>/dev/null || true
}

enable() {
    local win
    win="$(tmux list-windows -a -F '#{window_id} #{window_name}' 2>/dev/null | awk -v c="$CC" '$2==c{print $1; exit}')"
    if [[ -n "$win" ]]; then
        tmux set-window-option -t "$win" main-pane-width "$MAIN_WIDTH" 2>/dev/null || true
        tmux select-layout -t "$win" main-vertical 2>/dev/null || true
    fi
    # Global hook; the script self-guards to the command-center window. Passing
    # the focused window/pane as formats (expanded when the hook fires).
    tmux set-hook -g pane-focus-in \
        "run-shell -b 'bash \"$SCRIPT\" promote #{window_id} #{pane_id}'" 2>/dev/null || true
}

disable() {
    tmux set-hook -gu pane-focus-in 2>/dev/null || true
    tmux set-option -gu @cc_promoting 2>/dev/null || true
}

case "${1:-}" in
    promote) promote "${2:-}" "${3:-}" ;;
    enable)  enable ;;
    disable) disable ;;
    *) echo "usage: $0 {enable|disable|promote <wid> <pid>}" >&2; exit 2 ;;
esac
