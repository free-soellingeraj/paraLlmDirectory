# Tech Stack

## Overview
Technologies, tools, and dependencies used in the para-llm-directory project.

## Programming Language

### Bash
- **Version**: Compatible with Bash 3.2+ (macOS default) and Bash 4+
- **Usage**: All scripts are pure Bash shell scripts
- **Files**: `tmux-new-branch.sh`, `tmux-cleanup-branch.sh`, `envs.sh`, `install.sh`, `ctx`

**Notable Bash features used**:
- `set -e`: Exit on error (install.sh)
- `${var#*-}`: Parameter expansion for string manipulation
- `$(...)`: Command substitution
- `<<EOF`: Heredocs for multi-line strings
- Case statements for state machine navigation

---

## Runtime Dependencies

### tmux
- **Purpose**: Terminal multiplexer for managing sessions and windows
- **Commands used**:
  - `tmux new-window`: Create new window with specific name and directory
  - `tmux send-keys`: Send commands to window
  - `tmux list-windows`: List all windows for cleanup
  - `tmux kill-window`: Close windows during cleanup
  - `tmux display-popup`: Show interactive popups (requires tmux 3.2+)
  - `tmux source-file`: Reload configuration

### fzf
- **Purpose**: Fuzzy finder for interactive selection
- **Installation**: `brew install fzf`
- **Flags used**:
  - `--prompt`: Custom prompt text
  - `--height`: Limit display height
  - `--reverse`: List from top to bottom

### git
- **Purpose**: Version control operations
- **Commands used**:
  - `git clone`: Clone repositories
  - `git checkout`: Switch/create branches
  - `git branch`: List branches
  - `git fetch --prune`: Update remote refs
  - `git remote get-url`: Get remote URL
  - `git log --oneline @{u}..`: Check unpushed commits
  - `git diff`: Check for changes
  - `git ls-files --others`: List untracked files
  - `git show-ref`: Verify branch existence

### Claude Code
- **Purpose**: AI coding assistant that runs in each environment
- **Installation**: `npm install -g @anthropic-ai/claude-code`
- **Flags used**:
  - `--resume`: Continue previous session in same directory
  - `--dangerously-skip-permissions`: Skip permission prompts (used when resuming)

---

## System Requirements

### macOS
- Primary target platform
- Uses `brew` for package installation
- Tested on Darwin systems

### Linux
- Should work on most Linux distributions
- May need to adjust fzf installation method

---

## File Structure

```
para-llm-directory/
├── tmux-new-branch.sh      # Main creation/resume workflow
├── tmux-cleanup-branch.sh  # Environment cleanup
├── envs.sh                 # Status display utility
├── install.sh              # Automated installer
├── ctx                     # LLM context topic viewer
├── README.md               # Documentation
├── CLAUDE.md               # LLM instructions
└── .llm-context/           # LLM context documentation
    └── topics/             # Topic files
```

---

## No Build Tools Required

This project has **no build step**:
- No compilation needed
- No package.json or dependencies to install
- Scripts run directly after chmod +x
- Configuration is appended to ~/.tmux.conf

---

## Version Compatibility Notes

### tmux 3.2+
Required for `display-popup` command. Older versions will need alternative approach (separate window instead of popup).

### Bash 3.2 vs 4+
Scripts avoid Bash 4+ features (associative arrays, `|&` syntax) for macOS compatibility with default Bash.
# tech stack

## Overview
<!-- Describe what this topic covers -->

## Details
<!-- Add detailed information here -->

**File**: <!-- path/to/relevant/file.ext:line -->
