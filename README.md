# para-llm-directory

Tmux workflow for managing parallel Claude Code or Codex sessions across multiple feature branches.

<img width="1512" height="977" alt="Screenshot 2026-03-26 at 8 37 41 PM" src="https://github.com/user-attachments/assets/0c976b6a-d33a-4ec3-ac01-77c402f67e70" />

## What It Does

- **Ctrl+b c**: Create or resume a feature branch environment
  - Select a project from `~/code`
  - Choose to start new or resume existing feature
  - Clones repo to `~/code/envs/{Project}-{feature}/{Project}/`
  - Choose Claude Code or Codex for the new worktree
  - Opens tmux window and starts the selected REPL

- **Ctrl+b k**: Cleanup a feature branch environment
  - Select feature to delete
  - Warns about unpushed commits
  - Kills associated tmux window
  - Deletes the environment directory

- **Ctrl+b C**: Plain new window (original tmux behavior)

- **Ctrl+b y**: Choose or switch the active worktree between Claude Code and Codex
- **Ctrl+b a**: Voice input with whisper.cpp (press once to record, again to transcribe)
- **Ctrl+b p**: Voice playback for the latest active pane output
- **Shift+Enter**: Insert newline in Claude Code REPL (requires iTerm2 with CSI u — see below)
- **Mouse/trackpad**: Scroll tmux panes and click to select panes
- **Option+drag**: Select and copy text (Cmd+C to copy, iTerm2 native selection)

## Recommended Terminal

**iTerm2** is recommended on macOS for the best experience. macOS Terminal.app does not support extended key sequences, so features like Shift+Enter for newlines in the Claude Code REPL will not work.

To set up iTerm2:
1. Install [iTerm2](https://iterm2.com/)
2. Go to **Preferences > Profiles > Keys > General**
3. Enable **"Report modifiers using CSI u"**

## Prerequisites

```bash
# Install fzf (required for interactive selection)
brew install fzf

# Install Claude Code
npm install -g @anthropic-ai/claude-code

# Optional: Install Codex if you want Codex terminals
npm install -g @openai/codex

# Voice input dependencies
brew install sox whisper-cpp

# Voice playback dependency
pipx install edge-tts
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
6. The selected REPL starts automatically

### Resuming work on a feature

1. Press `Ctrl+b c`
2. Select your project
3. Choose "Yes - resume existing"
4. Select the branch from the list
5. The stored REPL for that environment resumes automatically

### Switching between Claude and Codex

From a worktree pane, press `Ctrl+b y` and choose Claude Code or Codex. The choice is stored per environment:

```text
.para-llm/
  repl
  transcript.log
  handoff.md
```

When switching from one product to the other, para-llm captures the pane transcript, writes `.para-llm/handoff.md`, and starts the selected REPL with a prompt to continue from that handoff. This transfers working context, not the product's hidden conversation state.

### Voice

- Press `Ctrl+b a` to start recording, then `Ctrl+b a` again to transcribe into the active pane.
- Press `Ctrl+b p` to speak the latest readable output from the active pane, then `Ctrl+b p` again to stop playback.

Voice is always installed by `install.sh`. STT uses `sox` and `whisper-cpp`. TTS uses Microsoft `edge-tts` with `en-US-AndrewNeural` by default and plays audio with `afplay` on macOS. Before playback, para-llm asks `codex` to turn the latest pane text into concise speakable prose, so code blocks, diffs, logs, and long output are summarized instead of read verbatim. (Headless `claude -p` was retired as a summarizer because it now meters against a separate paid credit pool — see ADR-009; set `TTS_SUMMARIZE=0` to skip summarization entirely.) While TTS is preparing the summary and audio, para-llm shows a live `TTS: <stage> (Ns)` progress indicator and plays a subtle repeating click so you know playback is working before the first utterance. If summarization is unavailable, playback falls back to the extracted pane text.

**Agent-authored voice scripts.** The coding agent in a pane can write the spoken briefing itself instead of having TTS re-summarize scrollback — it already knows what it just did, so the result is faster (no LLM summarize step), cheaper, and more accurate. `install.sh` registers a Claude Code skill (`para-voice-script`) and a Codex prompt (`/voice-script`); just ask the agent to "say that" / "make a voice script". When a fresh authored script exists for the pane, `Ctrl+b p` plays it directly and skips capture + summarization. Scripts expire after `TTS_AUTHORED_MAX_AGE` seconds (default 900) and then fall back to live capture. Manage them with `plugins/tts/voice-script.sh --show` / `--clear`.

### Upgrading existing environments

After installing, run:

```bash
$PARA_LLM_ROOT/scripts/para-llm-upgrade-envs.sh
```

This creates `.para-llm/` metadata for existing envs, defaults missing REPL choices to Claude, creates `AGENTS.md` from `CLAUDE.md` when needed, and attaches transcript logging to currently open panes.

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

## Project Hooks

Projects can define setup and teardown scripts that run automatically:

### `paraLlm_setup.sh`

If this script exists in your project root, it runs when creating or resuming an environment (before the REPL starts).

**Example for an iOS project:**
```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install pods if needed
if [[ ! -d "$SCRIPT_DIR/Pods" ]]; then
    (cd "$SCRIPT_DIR" && pod install)
fi

# Open Xcode
open "$SCRIPT_DIR/MyApp.xcworkspace"
```

### `paraLlm_teardown.sh`

If this script exists, it runs when cleaning up an environment (before deletion).

**Example:**
```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Close Xcode workspace
osascript -e "
    tell application \"Xcode\"
        repeat with doc in workspace documents
            if path of doc is \"$SCRIPT_DIR/MyApp.xcworkspace\" then
                close doc
            end if
        end repeat
    end tell
" 2>/dev/null
```

## Environment Status

Check the status of all your parallel environments:

```bash
# Add alias to ~/.zshrc
alias envs='~/code/para-llm-directory/envs.sh'

# Then run:
envs        # Show all environments with branch and status
envs -v     # Verbose: also show unpushed commit messages
```

**Output:**
```
ENVIRONMENT                              BRANCH                    STATUS
-----------                              ------                    ------
RiffyApp-delta-storage-refactor          delta-storage-refactor    clean
RiffyApp-new-feature                     new-feature               2 modified 1 untracked
MyProject-bugfix                         bugfix                    ↑3 unpushed
```

## Notes

- Base repos in `~/code` should not have dashes in their names (dashes indicate feature clones)
- Each feature gets a fresh clone, so changes are isolated
- Claude Code sessions are per-directory, so `--resume` works per feature
- Codex restore uses `codex resume --last`
- REPL switching captures terminal context into `.para-llm/handoff.md`; exact hidden session state is not portable between products
- Unpushed commits are detected before deletion to prevent data loss
- Project hooks are optional - environments work fine without them
