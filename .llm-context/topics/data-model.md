# Data Model

## Overview
Data structures, file system conventions, and state management in para-llm-directory. This project uses the file system as its primary data store with no database.

## File System as Data Store

### Environment Directory Structure
Each feature environment follows this structure:

```
~/code/envs/{ProjectName}-{BranchName}/
└── {ProjectName}/           # Cloned repository
    ├── .git/                # Git metadata
    ├── paraLlm_setup.sh     # Optional setup hook
    ├── paraLlm_teardown.sh  # Optional teardown hook
    └── ...                  # Project files
```

**Naming convention**: `{ProjectName}-{BranchName}`
- ProjectName: Name of base repo (no dashes allowed)
- Dash: Separator
- BranchName: Feature branch name

---

## Key Data Paths

| Data | Location | Purpose |
|------|----------|---------|
| Base repos | `~/code/{Project}/` | Original repositories to clone from |
| Environments | `~/code/envs/` | Feature branch working directories |
| tmux config | `~/.tmux.conf` | Key binding definitions |
| Config backup | `~/.tmux.conf.backup` | Pre-install config backup |

---

## State Derived from File System

The scripts derive all state from the file system at runtime:

### Available Projects
```bash
find "$CODE_DIR" -maxdepth 2 -name ".git" -type d | \
    xargs -I {} dirname {} | \
    grep -v '-'  # Exclude repos with dashes
```
**File**: `tmux-new-branch.sh:14-19`

### Existing Environments
```bash
for dir in "$ENVS_DIR"/${project}-*/; do
    basename "$dir" | sed "s|^${project}-||"
done
```
**File**: `tmux-new-branch.sh:28-33`

### Environment Status
Derived from git commands within each environment:
- `git branch --show-current`: Current branch
- `git diff --cached --numstat`: Staged changes
- `git diff --numstat`: Unstaged changes
- `git ls-files --others`: Untracked files
- `git log @{u}..`: Unpushed commits

**File**: `envs.sh:40-56`

---

## State Transitions

### Create Environment
```
[No directory] → mkdir ~/code/envs/{Project}-{Branch}/
              → git clone → ~/code/envs/{Project}-{Branch}/{Project}/
              → git checkout -b {Branch}
```

### Delete Environment
```
[Environment exists] → Run paraLlm_teardown.sh (if present)
                     → Kill tmux window
                     → rm -rf ~/code/envs/{Project}-{Branch}/
```

---

## No Persistent Configuration

The project intentionally avoids:
- Database or config files for environment tracking
- JSON/YAML state files
- Environment metadata files

**Rationale**:
- File system is the source of truth
- No sync issues between state and reality
- Easy manual intervention if needed
- Simpler implementation

---

## tmux Window State

tmux windows are named after branches for easy identification:

```bash
tmux new-window -n "$BRANCH_NAME" -c "$CLONE_DIR"
```

Window cleanup finds windows by name:
```bash
tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' | \
    grep " ${BRANCH_NAME}$"
```

**File**: `tmux-new-branch.sh:120`, `tmux-cleanup-branch.sh:101-106`

---

## Project Hooks Schema

Optional scripts that projects can define:

### paraLlm_setup.sh
- **Location**: Project root
- **Runs**: On create or resume (before Claude starts)
- **Purpose**: Project-specific initialization

### paraLlm_teardown.sh
- **Location**: Project root
- **Runs**: On cleanup (before directory deletion)
- **Purpose**: Project-specific cleanup

Both receive the working directory context automatically.
# data model

## Overview
<!-- Describe what this topic covers -->

## Details
<!-- Add detailed information here -->

**File**: <!-- path/to/relevant/file.ext:line -->
