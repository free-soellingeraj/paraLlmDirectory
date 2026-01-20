# Architectural Decisions

## Overview
Key architecture patterns and design decisions for the para-llm-directory project, a tmux-based workflow manager for parallel Claude Code sessions.

## ADR-001: Shell Scripts as Primary Implementation

**Decision**: Use pure Bash shell scripts instead of a compiled language or Node.js.

**Context**: The tool needs to integrate tightly with tmux and git, manage file system operations, and run interactively in terminal environments.

**Rationale**:
- Direct access to tmux commands without subprocess overhead
- No build step or dependency management needed
- Portable across macOS/Linux systems with bash
- Simple installation (just chmod +x and tmux config)
- Easy for users to modify/extend

**File**: `tmux-new-branch.sh`, `tmux-cleanup-branch.sh`, `envs.sh`

---

## ADR-002: Isolated Environment per Feature Branch

**Decision**: Clone the entire repository into a separate directory for each feature branch, rather than using git worktrees or branch switching.

**Context**: Multiple Claude Code sessions need to work on different features simultaneously.

**Rationale**:
- Complete isolation between features (no shared node_modules, build artifacts, etc.)
- Claude Code sessions are directory-based, so `--resume` works per-feature
- No risk of accidentally committing changes to wrong branch
- Supports project-specific setup scripts that may have side effects

**Structure**:
```
~/code/envs/
├── ProjectA-feature-1/
│   └── ProjectA/          # Full clone on feature-1 branch
└── ProjectA-feature-2/
    └── ProjectA/          # Full clone on feature-2 branch
```

**Trade-off**: Uses more disk space than worktrees, but provides better isolation.

**File**: `tmux-new-branch.sh:188-228`

---

## ADR-003: Convention-Based Project Hooks

**Decision**: Support optional `paraLlm_setup.sh` and `paraLlm_teardown.sh` scripts in project roots.

**Context**: Different projects have different setup needs (pod install, open IDE, etc.).

**Rationale**:
- Opt-in, doesn't affect projects without hooks
- Filename convention makes intent clear
- Runs automatically at the right lifecycle points
- Project-specific, checked into each project's repo

**File**: `tmux-new-branch.sh:122-126`, `tmux-cleanup-branch.sh:94-98`

---

## ADR-004: State Machine Navigation Pattern

**Decision**: Use a step-based state machine for multi-step interactive flows.

**Context**: The create/cleanup workflows have multiple steps with back-button support.

**Rationale**:
- Clear control flow with explicit step numbers
- Easy to add "← Back" option at any step
- Each step is self-contained
- Simple to extend with new steps

**Pattern**:
```bash
while true; do
    case $step in
        1) ... step=2 ;;
        2) ... step=3 ;;  # or step=1 for back
    esac
done
```

**File**: `tmux-new-branch.sh:66-251`, `tmux-cleanup-branch.sh:28-124`

---

## ADR-005: fzf for Interactive Selection

**Decision**: Use fzf as the primary UI for interactive selection.

**Context**: Need a consistent, user-friendly way to select from lists.

**Rationale**:
- Fuzzy search for quick selection
- Consistent UI across all selection prompts
- Handles keyboard navigation, escape to cancel
- Widely available via homebrew

**File**: `tmux-new-branch.sh:14-21`

---

## ADR-006: Project Naming Convention (No Dashes)

**Decision**: Base projects in `~/code` should not have dashes in their names.

**Context**: Need to distinguish between base repos and feature environment directories.

**Rationale**:
- Environment directories use pattern `{Project}-{feature}`
- Dash separates project name from feature name
- Prevents ambiguity when parsing environment names

**Trade-off**: Constraint on project naming, but simple and predictable.

**File**: `tmux-new-branch.sh:17-18`, `README.md:188-189`

---

## ADR-007: Claude Code Hooks for State Detection

**Decision**: Use Claude Code's built-in hooks system for accurate state detection instead of parsing terminal output.

**Context**: The Command Center feature needs to display Claude's state (ready/waiting/processing) with visual indicators. Previous implementations attempted to parse terminal output via tmux pipe-pane, but this proved unreliable due to timing issues and the complexity of Claude's UI rendering.

**Alternatives Considered**:

| Approach | Feasibility | Notes |
|----------|-------------|-------|
| Terminal output parsing | ⚠️ Unreliable | Timing issues, ANSI codes, UI complexity |
| tmux pipe-pane | ⚠️ Partially works | Real-time but still parsing terminal output |
| Polling capture-pane | ⚠️ Unreliable | Misses transient states, timing dependent |
| **Claude Code hooks** | ✅ Best option | Official API, accurate events, no parsing |

**How Claude Code Hooks Work**:

Claude Code provides a hooks system that fires events at specific lifecycle points:
- `SessionStart` / `SessionEnd` - Session lifecycle
- `PreToolUse` / `PostToolUse` - Tool execution
- `Stop` - Claude finishes responding
- `Notification` - Permission prompts, idle state

Hooks are configured in `~/.claude/settings.json`:
```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "*",
      "hooks": [{
        "type": "command",
        "command": "~/.para-llm/plugins/claude-state-monitor/hooks/state-tracker.sh pre_tool"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "~/.para-llm/plugins/claude-state-monitor/hooks/state-tracker.sh stop"
      }]
    }]
  }
}
```

**Architecture**:
```
┌─────────────────────────────────────────────────────────┐
│  Claude Code (in pane)                                  │
│       │                                                 │
│       ▼ (hooks fire on state changes)                  │
│  ┌─────────────────────────────────────────────────┐   │
│  │  state-tracker.sh (called by hooks)             │   │
│  │  - Receives event JSON via stdin                │   │
│  │  - Writes state to /tmp/claude-state/by-cwd/    │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  state-detector.sh (one per monitored pane)     │   │
│  │  - Polls every 1 second                         │   │
│  │  - Reads /tmp/claude-state/by-cwd/<path>.json   │   │
│  │  - Falls back to shell process check for non-   │   │
│  │    Claude terminals                             │   │
│  │  - Writes to /tmp/claude-pane-display/<id>      │   │
│  │  - Updates border: tmux set-option -p ...       │   │
│  └─────────────────────────────────────────────────┘   │
│       │                                                 │
│       ▼                                                 │
│  tmux pane-border-format reads display file            │
└─────────────────────────────────────────────────────────┘
```

**State Mapping**:
| Hook Event | State | Display |
|------------|-------|---------|
| `PreToolUse` | working | `Working: <tool_name>` |
| `PostToolUse` | working | `Working` |
| `Stop` | ready | `Waiting for Input` |
| `Notification (idle_prompt)` | ready | `Waiting for Input` |
| `Notification (permission_prompt)` | blocked | `Needs Action: Permission` |

**For Non-Claude Terminals**:
- Checks if shell has child processes
- Child processes running → `Working`
- No children (idle shell) → `Waiting for Input`

**Rationale**:
- **Accurate**: Uses official Claude Code events, not terminal parsing
- **Reliable**: No timing/race conditions from output streaming
- **Extensible**: Easy to add more hook types for future states
- **Dual mode**: Works for both Claude and regular terminals

**Plugin Structure**:
```
plugins/claude-state-monitor/
├── hooks/
│   ├── state-tracker.sh   # Hook handler, writes state to JSON
│   └── hooks-config.json  # Claude settings.json hooks template
├── state-detector.sh      # Per-pane monitor (reads hooks + shell state)
├── monitor-manager.sh     # Start/stop monitors for Command Center
├── get-pane-display.sh    # Helper for tmux pane-border-format
└── README.md              # Plugin documentation
```

**Installation**:
- `install.sh` copies hooks to `~/.para-llm/plugins/claude-state-monitor/hooks/`
- Merges hooks configuration into `~/.claude/settings.json`

**File**: `plugins/claude-state-monitor/`

**References**:
- Claude Code hooks: https://code.claude.com/docs/en/hooks.md
- Claude Code hooks guide: https://code.claude.com/docs/en/hooks-guide.md
- Feature branch: `feature-link-visuals-to-claude-completion`
