# Bugs Fixed

## Overview
Log of bugs encountered and fixed in the para-llm-directory project. Each entry documents the cause, fix, and affected files.

## Entry Template

```markdown
### BUG-XXX: Brief Description
**Date**: YYYY-MM-DD
**Symptom**: What the user observed
**Cause**: Root cause of the issue
**Fix**: How it was resolved
**File**: path/to/file.ext:line
```

---

## Bug Log

### BUG-001: Auto-close cleanup window
**Date**: 2024 (from commit history)
**Symptom**: After cleaning up a feature branch, the tmux popup window remained open
**Cause**: Missing `tmux kill-window` after successful deletion
**Fix**: Added `tmux kill-window` at the end of successful cleanup flow
**File**: `tmux-cleanup-branch.sh:119`

### BUG-002: Session terminates when closing last window
**Date**: 2026-01-18
**Symptom**: When using `ctrl+b k` with only one window in the tmux session, selecting "Just close window" or completing a cleanup would kill the entire tmux session. Reopening and using `ctrl+b v` would show "there are no windows".
**Cause**: `tmux kill-window` was called unconditionally. When the last window in a session is killed, tmux terminates the entire session (default tmux behavior).
**Fix**: Added `safe_kill_window()` function that checks window count before killing. If it's the last window, displays a message instead of killing.
**File**: `tmux-cleanup-branch.sh:5-16` (new function), `tmux-cleanup-branch.sh:54`, `tmux-cleanup-branch.sh:132`
**PR**: #8

### BUG-003: New feature opens in separate window instead of command center
**Date**: 2026-01-18
**Symptom**: When in command center view (`ctrl+b v`) and creating a new feature with `ctrl+b c`, the new window opens separately instead of appearing as a new tile in the command center.
**Cause**: `tmux-new-branch.sh` always created new windows with `tmux new-window`, which creates a standalone window. The command center had no knowledge of newly created windows.
**Fix**: Added `create_feature_window()` helper function that checks if command center exists and, if so, joins the new pane to it with `tmux join-pane`, reapplies tiled layout, and sets the pane title.
**File**: `tmux-new-branch.sh:10-46` (new function), lines 158, 206, 235, 279

### BUG-004: Command center creates zombie window
**Date**: 2026-01-20
**Symptom**: After opening and closing command center, an extra window with wrong pane remained in `ctrl+b w` list
**Cause**: `create_command_center()` used `swap-pane` for the first pane, which left the original window alive with an empty shell. Remaining panes used `join-pane` which killed their windows.
**Fix**: Changed to use `join-pane` for ALL panes uniformly, then kill the auto-created empty shell pane
**File**: `tmux-command-center.sh:138-185`

### BUG-005: Command center freezes tmux on open
**Date**: 2026-01-20
**Symptom**: After `ctrl+b v`, tmux became completely unresponsive. Couldn't interact or even use `ctrl+b w`. Had to kill terminal and reattach.
**Cause**: Background processes started with `&` weren't fully detached. tmux's `run-shell` waits for child processes, and the state-detector processes inherited file descriptors that kept the connection open.
**Fix**: Start background processes with `nohup ... </dev/null >/dev/null 2>&1 &` to fully detach from parent
**File**: `tmux-command-center.sh:218-226`, `plugins/claude-state-monitor/monitor-manager.sh:92-95`

### BUG-006: State detector always shows "Waiting for Input"
**Date**: 2026-01-20
**Symptom**: Status indicator never changed to "Working" even when Claude was running commands
**Cause**: Prompt detection checked for `❯` anywhere in last 5 lines, but `❯` also appears in conversation history (user messages). Detector always found a match.
**Fix**: Changed to check for `❯` at the START of a line only (`grep -qE '^[[:space:]]*❯'`), which matches the actual prompt, not history
**File**: `plugins/claude-state-monitor/state-detector.sh:42-51`

### BUG-007: Claude Code Stop hook never fires
**Date**: 2026-01-20
**Symptom**: State stayed "working" after Claude finished its turn. "Waiting for Input" only appeared after polling delay.
**Cause**: Claude Code's `Stop` hook appears to not fire reliably (or at all). Hooks for `PreToolUse` and `PostToolUse` work, but `Stop` does not update state files.
**Fix**: Removed reliance on hooks for state detection. Simplified to pure terminal-based detection (prompt visibility for Claude, child processes for regular terminals).
**File**: `plugins/claude-state-monitor/state-detector.sh` (full rewrite), `.llm-context/topics/product-features.md` (updated docs)

### BUG-008: Ctrl+b k in command center kills all windows
**Date**: 2026-01-20
**Symptom**: In command center, selecting "Just close window" from `Ctrl+b k` killed all windows except command center
**Cause**: `safe_kill_window()` called `tmux kill-window` without checking if we're in command center. This killed the command center window which contained all joined panes.
**Fix**: Added `in_command_center()` check. When in command center, kill just the active pane and reapply tiled layout instead of killing the window.
**File**: `tmux-cleanup-branch.sh:8-49`

### BUG-009: Installation always uses hardcoded ~/code directory
**Date**: 2026-01-22
**Symptom**: When installing para-llm-directory, it always creates environments in `~/code/envs` regardless of where the user's repositories are actually located.
**Cause**: `CODE_DIR` and `ENVS_DIR` were hardcoded at the top of multiple scripts (`tmux-new-branch.sh:3-4`, `envs.sh:7`, `tmux-cleanup-branch.sh:3`) as `$HOME/code` and `$HOME/code/envs`.
**Fix**:
1. Created `para-llm-config.sh` - a configuration loader that reads from `~/.para-llm/config`
2. Updated `install.sh` to prompt user for their preferred directories during installation
3. Updated all scripts to source `para-llm-config.sh` instead of hardcoding paths
**Files**: `para-llm-config.sh` (new), `install.sh:6-60`, `tmux-new-branch.sh:3-7`, `envs.sh:7-11`, `tmux-cleanup-branch.sh:3-7`

### BUG-011: Ctrl+b k feature cleanup kills unrelated windows
**Date**: 2026-01-23
**Symptom**: When using `Ctrl+b k` from a non-feature window to clean up a feature environment, the current window (and potentially windows in other sessions) were also killed.
**Cause**: Two issues: (1) `safe_kill_window()` was called unconditionally after feature cleanup, killing whatever window the user was in regardless of whether it was the feature window. (2) `tmux list-windows -a` searched across ALL sessions, potentially killing same-named windows elsewhere.
**Fix**: (1) Only call `safe_kill_window()` if the current window's name matches the branch being cleaned up. (2) Removed `-a` flag to scope window search to current session only.
**File**: `tmux-cleanup-branch.sh:173-186`, `tmux-cleanup-branch.sh:196` (removed)

### BUG-010: Claude launched without --dangerously-skip-permissions on new branches
**Date**: 2026-01-22
**Symptom**: When creating a new branch or attaching to a remote branch, Claude was launched without the `--dangerously-skip-permissions` flag, requiring manual permission grants for every action.
**Cause**: Some `tmux send-keys` commands in `tmux-new-branch.sh` used just `claude` or `claude --resume` without the permissions flag, while others correctly included it.
**Fix**: Updated all Claude launch commands to consistently use `claude --dangerously-skip-permissions` (with `--resume` added where appropriate for existing sessions).
**File**: `tmux-new-branch.sh:234`, `tmux-new-branch.sh:263-265`, `tmux-new-branch.sh:307-309`

### BUG-012: Window titles become "unknown" after sleep/wake
**Date**: 2026-02-01
**Symptom**: Window titles in the command center become "unknown" after laptop sleep/wake cycles or terminal session changes.
**Cause**: Pane display files were stored in volatile `/tmp/claude-pane-display/` which gets cleared on system sleep/reboot or by OS cleanup processes.
**Fix**: Move pane display storage to persistent `$PARA_LLM_ROOT/recovery/pane-display/` using the existing bootstrap mechanism (`~/.para-llm-root`). All scripts now read the bootstrap file to find PARA_LLM_ROOT, with fallback to `/tmp` for uninstalled state.
**Files**: `plugins/claude-state-monitor/get-pane-display.sh`, `plugins/claude-state-monitor/state-detector.sh`, `plugins/claude-state-monitor/hooks/state-tracker.sh`, `tmux-command-center.sh`, `install.sh`

---

## Known Bug-Prone Areas

### Git Remote Detection
The scripts assume all base repos have an `origin` remote configured. If a repo doesn't have a remote, the clone operation will fail.
**File**: `tmux-new-branch.sh:143-151`, `tmux-new-branch.sh:209-216`

### Branch Name Extraction
The cleanup script extracts branch name by taking everything after the first dash (`${ENV_NAME#*-}`). This works for standard patterns but could fail for edge cases.
**File**: `tmux-cleanup-branch.sh:92`

### Unpushed Commits Detection
The `@{u}` reference requires an upstream branch to be set. New branches without an upstream will show errors (suppressed with `2>/dev/null`).
**File**: `tmux-cleanup-branch.sh:74`, `envs.sh:48`

---

## Notes for Future Bug Entries

When fixing bugs, document:
1. How the bug was discovered (user report, testing, etc.)
2. Steps to reproduce
3. The actual vs expected behavior
4. Any related issues or PRs
