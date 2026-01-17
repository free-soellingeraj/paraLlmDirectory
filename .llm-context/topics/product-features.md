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

## Key Bindings Summary

| Binding | Action |
|---------|--------|
| `Ctrl+b c` | Create/resume feature environment |
| `Ctrl+b k` | Cleanup feature environment |
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
# product features

## Overview
<!-- Describe what this topic covers -->

## Details
<!-- Add detailed information here -->

**File**: <!-- path/to/relevant/file.ext:line -->
