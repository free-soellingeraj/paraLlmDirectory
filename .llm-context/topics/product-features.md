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
pane_index: status | directory | branch
```

Display files contain: `#[fg=<color>]<status> | <directory> | <branch>#[default]`

For non-git panes: `#[fg=default]No Git | <directory>#[default]` (no branch field)

Example titles:
- `0: Waiting for Input | myProject | feature-auth`
- `1: Working: Bash | myProject | bugfix-login`
- `2: Needs Action: Permission | myProject | feature-auth`
- `3: No Claude | myProject | main`
- `4: No Git | scripts`

**Active Pane Indicator**:
The currently selected pane is marked with asterisks (handled by tmux `pane-border-format`):
```
** 0: Waiting for Input | myProject | feature-auth **
```

**States**:
| State | Color | Meaning |
|-------|-------|---------|
| **Waiting for Input** | Green | Claude prompt visible, ready for user input |
| **Working** / **Working: \<tool\>** | Yellow | Claude actively processing or tool running |
| **Needs Action: Permission** | Cyan | Claude needs permission approval |
| **No Claude** | Green | Git pane with no Claude session running |
| **No Git** | Default | Pane not in a git repository |
| **♪ \<any state\>** | Magenta | TTS playback (or prep) active for this pane — overrides base color |

**TTS playback indicator**: When `Ctrl+b p` triggers playback in a pane, the
border + label switch to magenta with a `♪` prefix until playback finishes or
is stopped. Only one pane can play at a time — starting playback in a second
pane stops the first and "steals" the slot (a `TTS: stole playback from pane
%N` message is shown). The slot is tracked at `/tmp/para-llm-tts/active.pane`
and lifecycle is owned by `plugins/tts/toggle-tts.sh`. The indicator is
written by both `state-detector.sh` (polling) and the Claude state hook
(`state-tracker.sh`) so neither path strips it between events.

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

### 8. tmux Status Line Integration
Shows aggregate Claude state across all active sessions in the tmux status bar.

**Display Format**:
```
Claude: 2 ready, 1 working
Claude: 1 blocked
Claude: idle
```

**Colors**:
| State | Color | Meaning |
|-------|-------|---------|
| ready | Green | Sessions waiting for input |
| working | Yellow | Sessions actively processing |
| blocked | Cyan | Sessions needing permission |

**Emoji Mode** (optional):
```
🤖 ✓2, ⚙1
🤖 idle
```

**Configuration** (in `$PARA_LLM_ROOT/config`):
```bash
# Disable status line
STATUS_LINE_ENABLED=0

# Custom prefix (default: "Claude")
STATUS_LINE_PREFIX="CC"

# Use emoji icons instead of text
STATUS_LINE_EMOJI=1
```

**Auto-refresh**: Status updates every 2 seconds via tmux's `status-interval`.

**Implementation**:
- `plugins/claude-state-monitor/tmux-status.sh` - Reads state files and outputs formatted status
- Automatically added to tmux status-right by install.sh

**File**: `plugins/claude-state-monitor/tmux-status.sh`

---

### 9. Remote Workspace Save/Restore

Periodically pushes workspace state to a remote storage backend so it can be restored on a fresh instance.

**What gets saved**: Session state file (window names, projects, branches, git remote URLs) + config (~1KB total)
**What does NOT get saved**: Cloned git repos (too large). On restore, repos are re-cloned from their git remotes.

**Trigger**: Automatic, piggybacking on existing 1-minute tmux-resurrect save cycle (when enabled).

**Remote Management** (`Ctrl+b t`):
- Add/remove SSH remotes
- Select active remote
- Test connection
- Toggle remote save on/off

**Remote Restore**:
- On tmux start with no local state: offered "Pull & Restore from remote"
- On tmux start with local state: offered "Restore (remote)" alongside local restore
- Full restore: pulls state, clones repos from git remotes, creates tmux windows, launches Claude

**State Format** (6 columns):
```
window_name|pane_path|project|branch|had_claude|git_remote
```

**Remote Config** (`$PARA_LLM_ROOT/remotes/<name>`):
```bash
REMOTE_BACKEND="ssh"
REMOTE_HOST="user@host"
REMOTE_DIR="/home/user/.para-llm-remote"
REMOTE_SSH_KEY=""
```

**Configuration** (in `$PARA_LLM_ROOT/config`):
```bash
REMOTE_SAVE_ENABLED=1  # On by default, disable via Ctrl+b t menu
```

**Plugin Structure**:
```
plugins/remote-save/
├── remote-save.sh           # Push state to active remote (called by save hook)
├── remote-pull.sh           # Pull state from remote
├── remote-restore-full.sh   # Full restore: pull + clone + windows + Claude
├── remote-manage.sh         # fzf UI for managing remotes
└── backends/
    └── ssh.sh               # SSH/rsync backend
```

**File**: `plugins/remote-save/`

---

### 10. Voice Playback & Agent-Authored Voice Scripts (`Ctrl+b p`)

`Ctrl+b p` speaks the latest readable pane output; press again to stop. The
default path captures the pane, summarizes it with `codex` into speakable prose,
synthesizes audio with `edge-tts`, and plays it with `afplay`. A live status-line
indicator shows the current stage and a per-stage timer (`TTS: <stage> (Ns)`);
a repeating click plays while preparing. See the `debugging` topic for hang
diagnosis and BUG-018 for the timeout/cap behavior.

**Agent-authored voice scripts**: instead of re-summarizing scrollback, the
coding agent running in the pane can write the spoken briefing itself (it has
full context of what it just did), and `Ctrl+b p` plays it directly — no
capture, no LLM summarize step. This is faster, cheaper (no metered summarizer
call), and more accurate.

- **Mechanism**: `plugins/tts/voice-script.sh` records speakable prose for the
  current pane (resolved via `$TMUX_PANE`) to `/tmp/para-llm-tts/<pane>.authored.txt`.
  Supports `--clear` (revert to live capture) and `--show`.
- **Agent integration** (installed by `install.sh`, both agents supported):
  - Claude Code skill `para-voice-script` → `~/.claude/skills/para-voice-script/SKILL.md`
  - Codex prompt `/voice-script` → `~/.codex/prompts/voice-script.md`
  - Both are templated with the absolute path to `voice-script.sh` at install time.
- **Playback preference**: on `Ctrl+b p`, if a fresh authored script exists it is
  played directly (phase `using agent-authored script`); otherwise the live
  capture+summarize path runs. Freshness window is `TTS_AUTHORED_MAX_AGE`
  (default 900s; `0` = never expires).
- **Usage**: ask the agent to "say that" / "make a voice script", then `Ctrl+b p`.

**File**: `plugins/tts/voice-script.sh`, `plugins/tts/agent-skill/`, `plugins/tts/toggle-tts.sh`

---

## Key Bindings Summary

| Binding | Action |
|---------|--------|
| `Ctrl+b c` | Create/resume feature environment |
| `Ctrl+b k` | Cleanup feature environment |
| `Ctrl+b v` | Command Center (tiled view) |
| `Ctrl+b t` | Remote management menu |
| `Ctrl+b r` | Manual restore Claude sessions |

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
