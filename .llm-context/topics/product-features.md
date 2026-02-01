# Product Features

## Overview
para-llm-directory is a tmux-based workflow manager for running multiple Claude Code sessions in parallel across different feature branches. It provides keyboard shortcuts for creating, resuming, and cleaning up isolated development environments.

## Core Features

### 1. Create/Resume Feature Environment (`Ctrl+b c`)
Opens an interactive popup to create or resume a feature branch environment.

**Workflow options**:
- **Plain terminal**: Open a bare shell in `CODE_DIR` (no project context, no Claude)
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

### 8. Sound Notifications
Audio alerts when Claude Code finishes its turn or needs attention.

**Notification Types**:
| Event | Sound | When |
|-------|-------|------|
| `idle_prompt` | Glass | Claude finished and is waiting for input |
| `permission_prompt` | Sosumi | Claude needs permission to proceed |

**Smart Behavior**:
- Only plays when the pane is NOT currently focused
- Avoids annoying you when you're already looking at Claude

**Configuration** (via environment variables):
```bash
# Disable sounds entirely
export CLAUDE_SOUND_ENABLED=0

# Custom sound files (macOS .aiff format)
export CLAUDE_SOUND_IDLE=/path/to/done.aiff
export CLAUDE_SOUND_PERMISSION=/path/to/alert.aiff

# Play even when pane is focused (default: only when unfocused)
export CLAUDE_SOUND_ONLY_UNFOCUSED=0
```

**Implementation**:
- `plugins/claude-state-monitor/hooks/notification-sound.sh` - Plays sounds via `afplay`
- Triggered by Claude Code's `Notification` hook

**File**: `plugins/claude-state-monitor/hooks/notification-sound.sh`

---

## Key Bindings Summary

| Binding | Action |
|---------|--------|
| `Ctrl+b c` | Create/resume feature environment |
| `Ctrl+b k` | Cleanup feature environment |
| `Ctrl+b v` | Command Center (tiled view) |

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
