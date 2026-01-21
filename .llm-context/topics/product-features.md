# Product Features

## Overview
para-llm-directory is a tmux-based workflow manager for running multiple Claude Code sessions in parallel across different feature branches. It provides keyboard shortcuts for creating, resuming, and cleaning up isolated development environments.

## Core Features

### 1. Create/Resume Feature Environment (`Ctrl+b c`)
Opens an interactive popup to create or resume a feature branch environment.

**Workflow options**:
- **Resume**: Continue working on an existing local clone with `claude --resume`
- **Attach**: Checkout an existing remote branch into a new local environment
- **New**: Create a fresh feature branch from a new clone

**Process**:
1. Select a project from `~/code` (git repos without dashes in name)
2. Choose action (Resume/Attach/New)
3. Select existing branch or enter new branch name
4. Script clones repo to `~/code/envs/{Project}-{branch}/{Project}/`
5. Opens tmux window named after the branch
6. Starts Claude Code automatically

**File**: `tmux-new-branch.sh`

---

### 2. Cleanup Feature Environment (`Ctrl+b k`)
Safely removes a feature branch environment when work is complete.

**Safety features**:
- Warns about unpushed commits before deletion
- Requires confirmation before destructive action
- Runs project teardown hooks if defined

**Process**:
1. Select environment to delete
2. Confirm deletion
3. If unpushed commits exist, confirm again
4. Runs `paraLlm_teardown.sh` if present
5. Kills associated tmux window
6. Deletes environment directory

**File**: `tmux-cleanup-branch.sh`

---

### 3. Environment Status (`envs` command)
Shows status of all parallel development environments at a glance.

**Output columns**:
- Environment name
- Current branch
- Status (clean, modified files, unpushed commits)

**Flags**:
- `-v, --verbose`: Also show unpushed commit messages

**Example output**:
```
ENVIRONMENT                    BRANCH              STATUS
-----------                    ------              ------
MyApp-new-feature              new-feature         2 modified 1 untracked
MyApp-bugfix                   bugfix              ↑3 unpushed
```

**File**: `envs.sh`

---

### 4. Project Hooks
Optional scripts that run automatically during environment lifecycle.

**`paraLlm_setup.sh`**: Runs when creating or resuming an environment (before Claude starts)
- Install dependencies
- Open IDE
- Start local services

**`paraLlm_teardown.sh`**: Runs when cleaning up an environment (before deletion)
- Close IDE windows
- Stop local services
- Cleanup temporary files

**File**: `README.md:119-160`

---

### 5. Plain Terminal Fallback (`Ctrl+b C`)
Opens a standard tmux window without project context, preserving original tmux behavior.

**File**: `install.sh:44`

---

## Navigation Features

All selection screens support:
- **← Back**: Return to previous step
- **Esc/Ctrl+c**: Cancel operation
- **Type "back"**: Go back when entering text input
- **fzf fuzzy search**: Quick filtering of long lists

---

### 6. Command Center (`Ctrl+b v`)
Tiled view showing all active feature windows for at-a-glance monitoring.

**Features**:
- Joins all session windows into a single tiled layout
- Each tile shows the pane from one feature branch
- Pane borders display: `pane_index: project | branch`
- Direct interaction with any pane (keyboard input forwarded)

**Navigation**:
- Arrow keys to move between panes
- `Ctrl+b z` to zoom/unzoom a pane
- `Ctrl+b b` to toggle broadcast mode (type in all panes)

**File**: `tmux-command-center.sh`

---

### 7. Pane State Visual Indicators
Visual feedback showing whether each Command Center tile is waiting for input or actively working.

**Tile Title Bar Format**:
```
pane_index: status | project | branch
```

Example titles:
- `0: Waiting for Input | myProject | feature-auth`
- `1: Working | myProject | bugfix-login`

**Active Pane Indicator**:
The currently selected pane is marked with asterisks (handled by tmux `pane-border-format`):
```
** 0: Waiting for Input | myProject | feature-auth **
```

**Two States**:
| State | Color | Meaning |
|-------|-------|---------|
| **Waiting for Input** | Green | Prompt visible, ready for user input |
| **Working** | Yellow | Command running or Claude processing |

**Detection Method** (terminal-based, simple & reliable):

For Claude Code sessions:
- Checks if the Claude prompt (`❯`) is visible in the pane
- Prompt visible → "Waiting for Input"
- Prompt not visible → "Working"

For regular terminals (non-Claude):
- Checks if shell has child processes running
- No children → "Waiting for Input"
- Has children → "Working"

**Why terminal detection over hooks**:
- Claude Code's `Stop` hook doesn't fire reliably
- Prompt detection is simple and works consistently
- 0.3s polling provides responsive updates
- No complex state machine or priority logic needed

**Implementation** (plugin architecture):
- `plugins/claude-state-monitor/state-detector.sh` - Per-pane monitor using prompt/process detection
- `plugins/claude-state-monitor/monitor-manager.sh` - Starts/stops monitors with Command Center
- `plugins/claude-state-monitor/get-pane-display.sh` - Helper for tmux pane-border-format
- State written to `/tmp/claude-pane-display/<pane_id>`

**File**: `plugins/claude-state-monitor/`

---

### 8. Remote Sessions (SSH & Coder)
Run Claude Code on remote machines via SSH or Coder workspaces while maintaining full Command Center compatibility.

**Supported host types**:
- **SSH hosts**: Any host from `~/.ssh/config` or direct hostname
- **Coder workspaces**: Named workspaces or auto-discovery via `coder list`

**Configuration** (`~/.para-llm/remote-hosts.conf`):
```bash
# SSH hosts
ssh:devbox
ssh:gpu-server

# Coder workspaces (explicit)
coder:my-workspace

# Auto-discover all coder workspaces
coder:*
```

**Workflow** (`Ctrl+b c`):
1. Select a remote host from the "Remote" section
2. Script tests connectivity and discovers code directory
3. Lists git projects on the remote machine (with caching)
4. Select project and branch
5. Creates tmux window running: `ssh -t host "cd path && git checkout branch; claude"`

**Remote session naming**:
- Window names include hostname: `feature-xyz@devbox`
- Command Center displays 🌐 indicator for remote sessions

**Cleanup** (`Ctrl+b k`):
- Remote sessions show in separate "Remote Sessions" section
- Closing only kills the SSH connection
- No files deleted on remote (safety for shared machines)

**How it works**:
- Claude Code runs **on the remote machine**
- State detection works via terminal parsing (captures SSH output)
- Command Center integration is seamless

**Code directory discovery**:
Checks these paths on the remote in order: `~/code`, `~/projects`, `/workspace`

**Caching**:
- Code directory: cached 10 minutes
- Project list: cached 5 minutes
- Cache stored in `/tmp/para-llm-remote-cache/`

**Files**:
- `remote-utils.sh` - Shared remote operation functions
- `tmux-new-branch.sh` - Steps 4-6 for remote workflow

---

## Key Bindings Summary

| Binding | Action |
|---------|--------|
| `Ctrl+b c` | Create/resume feature environment (local or remote) |
| `Ctrl+b k` | Cleanup feature environment or close remote session |
| `Ctrl+b v` | Command Center (tiled view) |
| `Ctrl+b b` | Toggle broadcast mode (type in all panes) |
| `Ctrl+b C` | Plain new tmux window |

---

## Directory Conventions

```
~/code/
├── ProjectName/              # Base repos (no dashes in name)
├── para-llm-directory/       # This tool
└── envs/                     # Feature environments
    └── ProjectName-feature/
        └── ProjectName/      # Cloned repo
```
