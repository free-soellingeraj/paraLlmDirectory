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
- Scripts launched as `bash foo.sh` or via `#!/usr/bin/env bash` from tmux get `/bin/bash` 3.2 unless Homebrew bash is installed — don't assume it is. A `declare -A` killed the wake listener at startup (BUG-078).
- Use parallel indexed arrays instead of a map (`CMD_STEMS`/`CMD_FORMS` in `wake-listener.sh`).
- Under `set -u`, 3.2 treats `"${a[@]}"` on an EMPTY array as unbound; use `${a[@]+"${a[@]}"}` or loop on `${#a[@]}`.
- Run shell tests with `/bin/bash`, not `bash`, so they exercise the shell the scripts really get.

---

## Voice dependencies (installed by install.sh)

### Kokoro (local neural TTS for speak mode)
- **Purpose**: the voice speak mode (Ctrl+b o) narrates with; falls back to `say` if unavailable
- **Service**: `plugins/tts/kokoro-daemon.py`, one HTTP daemon on 127.0.0.1:8788 shared by every pane; `toggle-speak.sh` starts it
- **Runtime**: Homebrew `python3.11` (`KOKORO_PY`), because Homebrew's default python3 is newer than onnxruntime ships wheels for
- **Packages**: `kokoro-onnx==0.6.1` (pulls `onnxruntime`, `phonemizer`, `numpy`), `soundfile` — installed into that interpreter with `--break-system-packages`
- **System**: `espeak-ng` (daemon reads `/opt/homebrew/share/espeak-ng-data`)
- **Model files**: `~/.cache/kokoro-onnx/` (`KOKORO_MODEL_DIR`) — `kokoro-v1.0.fp16.onnx` (164 MB) + `voices-v1.0.bin` (28 MB, 54 voices), from the kokoro-onnx `model-files-v1.1` release, SHA-256 pinned in `install.sh`
- **Install**: `install.sh` (Homebrew only); idempotent, downloads via `.part` + checksum + rename
- **Verify**: `curl -s 127.0.0.1:8788/health` → `{"ok": true, ...}` while speak mode is on; failures land in `/tmp/para-speakloop/kokoro-daemon.log`

**File**: install.sh (`install_kokoro`), plugins/tts/kokoro-daemon.py
# tech stack

## Overview
<!-- Describe what this topic covers -->

## Details
<!-- Add detailed information here -->

**File**: <!-- path/to/relevant/file.ext:line -->
