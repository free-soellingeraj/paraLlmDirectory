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
CC_COOLDOWN="${PARA_CC_COOLDOWN:-0.4}"    # secs the guard holds after a promote to
                                          # absorb the focus-in echoes swap-pane emits
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Is this window the command-center? (accepts a window id/target)
is_cc() {
    [[ "$(tmux display-message -pt "$1" '#{window_name}' 2>/dev/null)" == "$CC" ]]
}

promote() {
    local wid="${1:-}" pid="${2:-}"
    [[ -n "$wid" ]] || wid="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    is_cc "$wid" || return 0
    # Cooldown guard FIRST. swap-pane below relocates the OLD main pane, and tmux
    # emits a pane-focus-in for it; without a guard that echo re-fires promote and
    # oscillates the big pane straight back. A plain flag cleared on return is too
    # fast — the echoes are async and arrive after we return. So the guard is held
    # by a background timer (see the release at the end).
    [[ "$(tmux show-option -gqv @cc_promoting 2>/dev/null)" == "1" ]] && return 0
    # Respect a manual full-zoom (Ctrl+b z) — don't fight the user.
    [[ "$(tmux display-message -pt "$wid" '#{window_zoomed_flag}' 2>/dev/null)" == "1" ]] && return 0

    local n main active
    n="$(tmux list-panes -t "$wid" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${n:-0}" -lt 2 ]] && return 0
    active="${pid:-$(tmux display-message -pt "$wid" '#{pane_id}' 2>/dev/null)}"
    main="$(tmux list-panes -t "$wid" -F '#{pane_id}' 2>/dev/null | head -1)"   # index 0 = main slot
    [[ -z "$active" || -z "$main" ]] && return 0
    [[ "$active" == "$main" ]] && return 0     # already big — nothing to do

    tmux set-option -g @cc_promoting 1 2>/dev/null || true
    # -d keeps the intended pane focused; the explicit select-pane re-asserts it
    # (the swap can drift focus to the displaced pane) so active == the big pane.
    tmux swap-pane -d -s "$active" -t "$main" 2>/dev/null
    tmux select-pane -t "$active" 2>/dev/null || true
    tmux set-window-option -t "$wid" main-pane-width "$MAIN_WIDTH" 2>/dev/null || true
    tmux select-layout -t "$wid" main-vertical 2>/dev/null || true
    # Release the guard after the echoes settle, then re-check: if focus moved to
    # ANOTHER pane during the cooldown (fast arrowing), its focus-in was absorbed,
    # so promote whatever is active now. Converges once active == main.
    ( sleep "$CC_COOLDOWN"
      tmux set-option -g @cc_promoting 0 2>/dev/null || true
      bash "$SCRIPT" promote "$wid" >/dev/null 2>&1 ) &
}

enable() {
    # pane-focus-in hooks only fire when focus-events is on — without this the
    # big pane can't follow your selection at all.
    tmux set-option -g focus-events on 2>/dev/null || true
    tmux set-option -g @cc_promoting 0 2>/dev/null || true   # clear any stuck guard
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
