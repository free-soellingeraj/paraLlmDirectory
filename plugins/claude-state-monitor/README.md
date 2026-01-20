# Claude State Monitor Plugin

Real-time visual feedback for Claude Code state in Command Center tiles.

## Overview

This plugin uses tmux's `pipe-pane` feature to stream pane output in real-time and detect Claude Code's state (ready, waiting, processing). It updates pane border colors and title bars accordingly.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Claude Code (in pane)                                  │
│       │                                                 │
│       ▼ (real-time stream via pipe-pane -O)            │
│  ┌─────────────────────────────────────────────────┐   │
│  │  state-detector.sh (one per monitored pane)     │   │
│  │  - Receives pane output via stdin               │   │
│  │  - Buffers and debounces (~200ms)               │   │
│  │  - Pattern matches for state indicators         │   │
│  │  - Updates tmux pane border style               │   │
│  │  - Writes display string for border format      │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `state-detector.sh` | Per-pane stream processor. Receives piped output, detects state, updates visuals. |
| `monitor-manager.sh` | Lifecycle manager. Attaches/detaches pipe-pane for Command Center panes. |
| `get-pane-display.sh` | Helper for tmux pane-border-format. Looks up display file by pane index. |
| `README.md` | This documentation |

## How It Works

### 1. Attaching the Monitor

When Command Center opens, `monitor-manager.sh` attaches a pipe to each pane:

```bash
tmux pipe-pane -t "$pane_id" -O "$PLUGIN_DIR/state-detector.sh $pane_id $project $branch"
```

### 2. Stream Processing

`state-detector.sh` receives all pane output via stdin and:

1. **Buffers** incoming characters (Claude streams character-by-character)
2. **Debounces** processing to every ~200ms to avoid excessive updates
3. **Pattern matches** against the buffer:
   - `❯` prompt at line start → **ready** (green border)
   - `Yes`, `No`, `Allow`, `Deny` → **waiting** (cyan border)
   - `thinking)` → **processing** (yellow border)
4. **Updates** tmux pane border style via `tmux set-option -p`
5. **Writes** display string to `/tmp/claude-pane-display/<pane_id>`

### 3. Detaching the Monitor

When Command Center closes, `monitor-manager.sh` detaches all pipes:

```bash
tmux pipe-pane -t "$pane_id"  # Empty command stops piping
```

## State Detection Patterns

| State | Pattern | Border Color | Label |
|-------|---------|--------------|-------|
| Ready | `^❯` (prompt at line start) | Green | `✓ ready` |
| Waiting | `Yes\|No\|Allow\|Deny` | Cyan | `⏸ waiting` |
| Processing | `thinking)` | Yellow | `⟳ working` |
| Unknown | (default) | Default | (none) |

## Display Format

The pane border displays:
```
pane_index: project | branch | status
```

Example:
```
0: myProject | feature-auth | ✓ ready
```

Active pane is marked with asterisks:
```
** 0: myProject | feature-auth | ✓ ready **
```

## Temp Files

| Path | Purpose |
|------|---------|
| `/tmp/claude-pane-display/<pane_id>` | Display string for each pane (read by pane-border-format) |

## Integration with Command Center

The Command Center (`tmux-command-center.sh`) integrates with this plugin:

1. Sets `pane-border-format` to read from display files:
   ```bash
   tmux set-window-option -t "$COMMAND_CENTER" pane-border-format \
       ' #{pane_index}: #(cat /tmp/claude-pane-display/#{s/%//:pane_id} 2>/dev/null || echo "#{pane_title}") '
   ```

2. Calls `monitor-manager.sh attach` when opening Command Center
3. Calls `monitor-manager.sh detach` when closing Command Center

## Why pipe-pane?

See **ADR-007** in `.llm-context/topics/architectural-decisions.md` for the full decision record.

**TL;DR**: tmux has no content-change hook. Polling works but has 1-second latency and CPU overhead. `pipe-pane` provides real-time, event-driven state detection using built-in tmux functionality.

## Requirements

- tmux 3.1+ (for per-pane border styles with `-p` flag)
- Bash 3.2+ (macOS compatible)

## Usage

```bash
# Attach monitors to all panes in command-center window
./monitor-manager.sh attach

# Detach all monitors
./monitor-manager.sh detach

# Check status
./monitor-manager.sh status
```
