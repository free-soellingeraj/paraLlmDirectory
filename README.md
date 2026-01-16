# para-llm-directory

Tmux workflow for managing parallel Claude Code sessions across multiple feature branches.

## What It Does

- **Ctrl+b c**: Create or resume a feature branch environment
  - Select a project from `~/code`
  - Choose to start new or resume existing feature
  - Clones repo to `~/code/envs/{Project}-{feature}/{Project}/`
  - Opens tmux window and starts Claude Code

- **Ctrl+b k**: Cleanup a feature branch environment
  - Select feature to delete
  - Warns about unpushed commits
  - Kills associated tmux window
  - Deletes the environment directory

- **Ctrl+b C**: Plain new window (original tmux behavior)

## Prerequisites

```bash
# Install fzf (required for interactive selection)
brew install fzf

# Install Claude Code
npm install -g @anthropic-ai/claude-code
```

## Installation

### 1. Clone this repo

```bash
cd ~/code
git clone git@github.com:free-soellingeraj/para-llm-directory.git
```

### 2. Make scripts executable

```bash
chmod +x ~/code/para-llm-directory/tmux-new-branch.sh
chmod +x ~/code/para-llm-directory/tmux-cleanup-branch.sh
```

### 3. Add to ~/.tmux.conf

```bash
# Ctrl+b c: interactive project + branch selection, creates clone in envs/
bind-key c display-popup -E -w 60% -h 60% "~/code/para-llm-directory/tmux-new-branch.sh"

# Ctrl+b k: cleanup/delete a feature branch environment
bind-key k display-popup -E -w 60% -h 60% "~/code/para-llm-directory/tmux-cleanup-branch.sh"

# Ctrl+b C: original behavior (plain new window)
bind-key C new-window -c "#{pane_current_path}"
```

### 4. Reload tmux config

```bash
tmux source-file ~/.tmux.conf
```

### 5. Create the envs directory

```bash
mkdir -p ~/code/envs
```

## Directory Structure

```
~/code/
├── MyProject/                    # Base repo (must have git remote)
├── AnotherProject/               # Another base repo
├── para-llm-directory/           # This repo (scripts)
└── envs/                         # Feature environments
    ├── MyProject-feature-1/
    │   └── MyProject/            # Cloned repo on feature-1 branch
    └── MyProject-bugfix-2/
        └── MyProject/            # Cloned repo on bugfix-2 branch
```

## Usage

### Starting a new feature

1. Press `Ctrl+b c`
2. Select your project
3. Choose "No - start new feature/bug"
4. Enter the feature/branch name
5. Wait for clone to complete
6. Claude Code starts automatically

### Resuming work on a feature

1. Press `Ctrl+b c`
2. Select your project
3. Choose "Yes - resume existing"
4. Select the branch from the list
5. Claude Code resumes with `--resume`

### Cleaning up a finished feature

1. Press `Ctrl+b k`
2. Select the feature to delete
3. Confirm deletion
4. (If unpushed commits exist, confirm again)
5. Tmux window closes and directory is deleted

### Navigation

- All selection screens have `← Back` option to go to previous step
- Press `Esc` or `Ctrl+c` to cancel at any time
- When typing branch name, type `back` to go back

## Notes

- Base repos in `~/code` should not have dashes in their names (dashes indicate feature clones)
- Each feature gets a fresh clone, so changes are isolated
- Claude Code sessions are per-directory, so `--resume` works per feature
- Unpushed commits are detected before deletion to prevent data loss
