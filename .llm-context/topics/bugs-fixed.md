# Bugs Fixed

## Overview
Log of bugs encountered and fixed in the para-llm-directory project. Each entry documents the cause, fix, and affected files.

## Entry Template

```markdown
### BUG-XXX: Brief Description
**Date**: YYYY-MM-DD
**Symptom**: What the user observed
**Cause**: Root cause of the issue
**Fix**: How it was resolved
**File**: path/to/file.ext:line
```

---

## Bug Log

### BUG-001: Auto-close cleanup window
**Date**: 2024 (from commit history)
**Symptom**: After cleaning up a feature branch, the tmux popup window remained open
**Cause**: Missing `tmux kill-window` after successful deletion
**Fix**: Added `tmux kill-window` at the end of successful cleanup flow
**File**: `tmux-cleanup-branch.sh:119`

### BUG-002: Session terminates when closing last window
**Date**: 2026-01-18
**Symptom**: When using `ctrl+b k` with only one window in the tmux session, selecting "Just close window" or completing a cleanup would kill the entire tmux session. Reopening and using `ctrl+b v` would show "there are no windows".
**Cause**: `tmux kill-window` was called unconditionally. When the last window in a session is killed, tmux terminates the entire session (default tmux behavior).
**Fix**: Added `safe_kill_window()` function that checks window count before killing. If it's the last window, displays a message instead of killing.
**File**: `tmux-cleanup-branch.sh:5-16` (new function), `tmux-cleanup-branch.sh:54`, `tmux-cleanup-branch.sh:132`
**PR**: #8

### BUG-003: New feature opens in separate window instead of command center
**Date**: 2026-01-18
**Symptom**: When in command center view (`ctrl+b v`) and creating a new feature with `ctrl+b c`, the new window opens separately instead of appearing as a new tile in the command center.
**Cause**: `tmux-new-branch.sh` always created new windows with `tmux new-window`, which creates a standalone window. The command center had no knowledge of newly created windows.
**Fix**: Added `create_feature_window()` helper function that checks if command center exists and, if so, joins the new pane to it with `tmux join-pane`, reapplies tiled layout, and sets the pane title.
**File**: `tmux-new-branch.sh:10-46` (new function), lines 158, 206, 235, 279

### BUG-004: Command center creates zombie window
**Date**: 2026-01-20
**Symptom**: After opening and closing command center, an extra window with wrong pane remained in `ctrl+b w` list
**Cause**: `create_command_center()` used `swap-pane` for the first pane, which left the original window alive with an empty shell. Remaining panes used `join-pane` which killed their windows.
**Fix**: Changed to use `join-pane` for ALL panes uniformly, then kill the auto-created empty shell pane
**File**: `tmux-command-center.sh:138-185`

### BUG-005: Command center freezes tmux on open
**Date**: 2026-01-20
**Symptom**: After `ctrl+b v`, tmux became completely unresponsive. Couldn't interact or even use `ctrl+b w`. Had to kill terminal and reattach.
**Cause**: Background processes started with `&` weren't fully detached. tmux's `run-shell` waits for child processes, and the state-detector processes inherited file descriptors that kept the connection open.
**Fix**: Start background processes with `nohup ... </dev/null >/dev/null 2>&1 &` to fully detach from parent
**File**: `tmux-command-center.sh:218-226`, `plugins/claude-state-monitor/monitor-manager.sh:92-95`

### BUG-006: State detector always shows "Waiting for Input"
**Date**: 2026-01-20
**Symptom**: Status indicator never changed to "Working" even when Claude was running commands
**Cause**: Prompt detection checked for `❯` anywhere in last 5 lines, but `❯` also appears in conversation history (user messages). Detector always found a match.
**Fix**: Changed to check for `❯` at the START of a line only (`grep -qE '^[[:space:]]*❯'`), which matches the actual prompt, not history
**File**: `plugins/claude-state-monitor/state-detector.sh:42-51`

### BUG-007: Claude Code Stop hook never fires
**Date**: 2026-01-20
**Symptom**: State stayed "working" after Claude finished its turn. "Waiting for Input" only appeared after polling delay.
**Cause**: Claude Code's `Stop` hook appears to not fire reliably (or at all). Hooks for `PreToolUse` and `PostToolUse` work, but `Stop` does not update state files.
**Fix**: Removed reliance on hooks for state detection. Simplified to pure terminal-based detection (prompt visibility for Claude, child processes for regular terminals).
**File**: `plugins/claude-state-monitor/state-detector.sh` (full rewrite), `.llm-context/topics/product-features.md` (updated docs)

### BUG-008: Ctrl+b k in command center kills all windows
**Date**: 2026-01-20
**Symptom**: In command center, selecting "Just close window" from `Ctrl+b k` killed all windows except command center
**Cause**: `safe_kill_window()` called `tmux kill-window` without checking if we're in command center. This killed the command center window which contained all joined panes.
**Fix**: Added `in_command_center()` check. When in command center, kill just the active pane and reapply tiled layout instead of killing the window.
**File**: `tmux-cleanup-branch.sh:8-49`

### BUG-009: Installation always uses hardcoded ~/code directory
**Date**: 2026-01-22
**Symptom**: When installing para-llm-directory, it always creates environments in `~/code/envs` regardless of where the user's repositories are actually located.
**Cause**: `CODE_DIR` and `ENVS_DIR` were hardcoded at the top of multiple scripts (`tmux-new-branch.sh:3-4`, `envs.sh:7`, `tmux-cleanup-branch.sh:3`) as `$HOME/code` and `$HOME/code/envs`.
**Fix**:
1. Created `para-llm-config.sh` - a configuration loader that reads from `~/.para-llm/config`
2. Updated `install.sh` to prompt user for their preferred directories during installation
3. Updated all scripts to source `para-llm-config.sh` instead of hardcoding paths
**Files**: `para-llm-config.sh` (new), `install.sh:6-60`, `tmux-new-branch.sh:3-7`, `envs.sh:7-11`, `tmux-cleanup-branch.sh:3-7`

### BUG-011: Ctrl+b k feature cleanup kills unrelated windows
**Date**: 2026-01-23
**Symptom**: When using `Ctrl+b k` from a non-feature window to clean up a feature environment, the current window (and potentially windows in other sessions) were also killed.
**Cause**: Two issues: (1) `safe_kill_window()` was called unconditionally after feature cleanup, killing whatever window the user was in regardless of whether it was the feature window. (2) `tmux list-windows -a` searched across ALL sessions, potentially killing same-named windows elsewhere.
**Fix**: (1) Only call `safe_kill_window()` if the current window's name matches the branch being cleaned up. (2) Removed `-a` flag to scope window search to current session only.
**File**: `tmux-cleanup-branch.sh:173-186`, `tmux-cleanup-branch.sh:196` (removed)

### BUG-010: Claude launched without --dangerously-skip-permissions on new branches
**Date**: 2026-01-22
**Symptom**: When creating a new branch or attaching to a remote branch, Claude was launched without the `--dangerously-skip-permissions` flag, requiring manual permission grants for every action.
**Cause**: Some `tmux send-keys` commands in `tmux-new-branch.sh` used just `claude` or `claude --resume` without the permissions flag, while others correctly included it.
**Fix**: Updated all Claude launch commands to consistently use `claude --dangerously-skip-permissions` (with `--resume` added where appropriate for existing sessions).
**File**: `tmux-new-branch.sh:234`, `tmux-new-branch.sh:263-265`, `tmux-new-branch.sh:307-309`

### BUG-012: Window titles become "unknown" after sleep/wake
**Date**: 2026-02-01
**Symptom**: Window titles in the command center become "unknown" after laptop sleep/wake cycles or terminal session changes.
**Cause**: Pane display files were stored in volatile `/tmp/claude-pane-display/` which gets cleared on system sleep/reboot or by OS cleanup processes.
**Fix**: Move pane display storage to persistent `$PARA_LLM_ROOT/recovery/pane-display/` using the existing bootstrap mechanism (`~/.para-llm-root`). All scripts now read the bootstrap file to find PARA_LLM_ROOT, with fallback to `/tmp` for uninstalled state.
**Files**: `plugins/claude-state-monitor/get-pane-display.sh`, `plugins/claude-state-monitor/state-detector.sh`, `plugins/claude-state-monitor/hooks/state-tracker.sh`, `tmux-command-center.sh`, `install.sh`

### BUG-013: Hooks-based state tracking never updates pane borders
**Date**: 2026-02-01
**Symptom**: When Claude Code hooks fire (PreToolUse, PostToolUse, Stop, etc.), the pane border status labels don't update. Only the polling-based state-detector updates work.
**Cause**: The `state-tracker.sh` script (called by Claude Code hooks) expected a pane mapping file at `/tmp/claude-pane-mapping/by-cwd/<cwd_safe>` containing PANE_ID, PROJECT, and BRANCH. However, this mapping file was never created by any script.
**Fix**: Modified `state-detector.sh` to create the pane mapping file when it starts monitoring a pane. The mapping is indexed by the pane's working directory (CWD) so that `state-tracker.sh` can look up which tmux pane corresponds to the CWD that Claude reports in its hook input.
**Files**: `plugins/claude-state-monitor/state-detector.sh:27-47` (new create_pane_mapping function), `plugins/claude-state-monitor/state-detector.sh:166-173` (cleanup)

### BUG-014: Default CODE_DIR uses ~/code instead of current directory
**Date**: 2026-02-20
**Symptom**: First install defaults `CODE_DIR` to `~/code` instead of the directory the user is currently in, forcing users to manually type their preferred path.
**Cause**: `DEFAULT_CODE_DIR` was hardcoded to `$HOME/code` in both `install.sh` and `para-llm-config.sh`.
**Fix**: Changed `DEFAULT_CODE_DIR` to `$(pwd)` so the installer defaults to wherever the user runs it from.
**Files**: `install.sh:43`, `para-llm-config.sh:10`
**Issue**: #43

### BUG-015: Tool only supports macOS (brew) for dependency installation
**Date**: 2026-02-20
**Symptom**: Linux users cannot install dependencies (fzf, sox, whisper-cpp) because the installer only uses `brew install`.
**Cause**: All package installation commands were hardcoded to use Homebrew (`brew install`).
**Fix**: Added `detect_package_manager()` and `pkg_install()` functions that support brew, apt, dnf, pacman, and apk. Replaced all `brew install` calls with `pkg_install`. Updated error messages in STT plugin scripts to suggest generic package manager usage instead of brew-specific commands.
**Files**: `install.sh:16-37` (new functions), `install.sh:140,148,182` (replaced calls), `plugins/stt/toggle-stt.sh:22,26`, `plugins/stt/transcribe.sh:34`
**Issue**: #44

### BUG-016: STT (Ctrl+b a) transcribes every recording as "you"
**Date**: 2026-05-17
**Symptom**: Every `Ctrl+b a` recording produced the literal string `you` (or sometimes `Thank you.`, `Thanks for watching.`), regardless of what was spoken.
**Cause**: Two layered issues. (1) The terminal app hosting tmux had no macOS microphone permission, so `rec` connected to CoreAudio successfully but received only silence — the WAV file was full-sized but contained ~0.000015 RMS amplitude (essentially noise floor). (2) Whisper's `ggml-base.en` model has a strong prior to emit "you" / "thank you" / "thanks for watching" when fed silent audio (a well-known artifact of its YouTube training data). The 1000-byte file-size floor in `toggle-stt.sh` only catches near-instantaneous taps; it does not catch silent-but-long recordings.
**Fix**: Three guardrails. (1) `toggle-stt.sh` now runs `sox <wav> -n stat` before invoking the transcriber and rejects audio with RMS below 0.003 with the message `STT: no audible audio (RMS=...; check mic permission for your terminal app)`. (2) `rec` stderr now goes to `/tmp/para-llm-stt/rec.log` instead of `/dev/null` so silent-failure modes leave a trail. (3) `transcribe.sh` filters known Whisper hallucination strings (case-insensitive, terminal-punctuation tolerant): `you`, `thank you`, `thank you for watching`, `thanks for watching`, `thanks`, `bye`, `[blank_audio]`, `(silence)`. The filter only matches whole-transcript equality so real speech containing the word "you" passes through. User-side remediation: enable mic permission for the terminal app in System Settings → Privacy & Security → Microphone and relaunch the terminal.
**File**: `plugins/stt/toggle-stt.sh:58-78`, `plugins/stt/transcribe.sh:66-83`

### BUG-017: TTS (Ctrl+b p) computes for a long time then plays two offset voices
**Date**: 2026-06-15
**Symptom**: Pressing `Ctrl+b p` to read a pane aloud would "compute" far longer than normal, then start two overlapping playbacks of the same text offset by a few seconds.
**Cause**: Re-entrancy race in `toggle-tts.sh`. The slow step is an LLM call in `summarize-for-speech.sh` (`claude -p`/`codex exec`) plus `edge-tts`, taking 15–60s. Seeing nothing happen, the user naturally presses `Ctrl+b p` again, and the script had no protection against running `start_playback` twice for the same pane: (1) the start-vs-stop decision (`is_playing`) and the prep claim (`echo $$ > PREP_PID_FILE`) were separated by `acquire_playback_slot`, and that slot logic only steals from *other* panes, so a same-pane re-entry wasn't deduped (TOCTOU); (2) the `TERM`/`INT` trap (`cleanup_on_exit`) never called `exit`, so a prepping instance killed by a second press would, after its foreground child returned, *resume* and fall through to `afplay`; (3) `stop_playback` killed only the bash PID, not its descendants, so the orphaned summarizer/`edge-tts` kept computing. Two concurrent LLM calls also explained the extra-long compute.
**Fix**: (1) Added an atomic per-pane toggle lock (`mkdir`-based mutex at `$TTS_DIR/<pane>.toggle.lock`) around the start-vs-stop decision; the prep slot is now claimed (`echo $$ > PREP_PID_FILE`) *while still holding the lock*, before any slow work, so a second press reliably sees the first as already-preparing and treats its press as a stop. (2) Split the signal trap into `cleanup_on_signal` (TERM/INT) which tears down and `exit 0`s, vs `cleanup_on_exit` (EXIT) — a killed prepping instance can no longer resume into `afplay`. (3) Added `kill_tree()` (recursive `pgrep -P`) used by `stop_playback`/`stop_playback_for_pane` so a stop interrupts the in-flight summarizer/`edge-tts`. (4) Added `still_owner()` guards before `edge-tts` and before `afplay` so an instance stopped/stolen mid-prep aborts without playing. Net effect: one playback per logical start; a second press during prep cleanly stops the first (standard toggle semantics).
**File**: `plugins/tts/toggle-tts.sh:46-90` (helpers), `:191-213` (traps), `:266-294` (ownership guards), `:303-315` (locked dispatch)

### BUG-018: TTS (Ctrl+b p) hangs — "just beeps for a long time"
**Date**: 2026-06-16
**Symptom**: After pressing `Ctrl+b p`, the "preparing" indicator beep (`/System/Library/Sounds/Tink.aiff`) loops for a very long time and speech never starts, so it sounds like a hang.
**Cause**: The ambient beep loop (`start_ambient_loop`, `while true` over `afplay`) runs for the *entire* preparation phase and had no time cap of its own. The prep phase itself had no timeout on either of its slow steps: the LLM summarizer in `summarize-for-speech.sh` (`claude -p`/`codex exec`, normally 15–60s) or the `edge-tts` audio synthesis (a network call to Microsoft). If the summarizer backend hung or the network stalled, the beep looped indefinitely because nothing ever ended the prep phase. BUG-017 fixed double-firing but not the unbounded duration of a *single* prep.
**Fix**: Added timeouts at three layers, using a portable `timeout`/`gtimeout` lookup (GNU coreutils installs it as `gtimeout` on macOS; calls run uncapped if neither is present). (1) `summarize-for-speech.sh` wraps the `claude`/`codex` call in `timeout -k 5 $TTS_SUMMARIZE_TIMEOUT` (default 60s) and, on any non-zero exit, removes the (possibly truncated) output and exits 1 so the caller falls back to the raw pane text instead of speaking a half-finished sentence. (2) `toggle-tts.sh` wraps `edge-tts` in `timeout -k 5 $TTS_SYNTH_TIMEOUT` (default 60s) — note `edge-tts` is **not** local: it opens a `wss://speech.platform.bing.com/...` WebSocket to Microsoft's online read-aloud service (`edge_tts/constants.py`, `communicate.py` via `aiohttp`), so a network stall genuinely hangs here. (3) `start_ambient_loop` gained a hard cap (`$TTS_AMBIENT_MAX_SECONDS`, default 120s, via the subshell's `SECONDS` builtin) as a final safety net so the beep can never loop forever regardless of cause. All three are configurable in `config` (0 disables each cap). Also added a live progress indicator (`set_phase`/`start_progress_loop`) that shows `TTS: <stage> (Ns)` in the status line with a per-stage timer and appends a timestamped trail to `/tmp/para-llm-tts/<pane>.progress.log`, so a hang is now visible and you can tell *which* stage stalled. Verified the timeout with a fake backend that hangs and ignores SIGTERM (SIGKILLed after the grace period, script exits 1, stale output discarded) and the progress loop in isolation (correct per-stage timers; ordering bug found+fixed where `start_progress_loop`'s internal `stop_progress_loop` wiped the just-set phase).
**File**: `plugins/tts/summarize-for-speech.sh:11-37` (timeout helper), `:48-58` (capped backends), `:71-84` (fallback on failure); `plugins/tts/toggle-tts.sh:43-60` (config + timeout lookup), `:223-285` (set_phase / progress loop), `:300-314` (ambient cap), `:333-352` (phases), `:365-378` (edge-tts timeout); defaults in `install.sh:180-195`

### BUG-019: STT (Ctrl+b a) stuck — orphaned recorder holds the mic, every press starts a new recording
**Date**: 2026-06-16
**Symptom**: "STT is broke." `Ctrl+b a` no longer toggles cleanly — a `rec` process stays alive holding the microphone, and pressing the key again starts *another* recording instead of stopping the first. Observed live: `rec -b 16 -c 1 -r 16000 /tmp/para-llm-stt/audio.wav` running with **no** `recording.pid` file present.
**Cause**: `is_recording()` keyed the start-vs-stop decision *solely* on the existence of a valid PID file. If the PID file is removed while the `rec` process is still alive — a desync that can arise from a stop path where `kill` fails but `rm -f "$PID_FILE"` still runs, a rapid double-press race between two backgrounded `run-shell -b` invocations, or an external `kill` of the shell but not its `rec` child — the toggle permanently believes nothing is recording. Every subsequent press then takes the `start_recording` branch, stacking orphaned recorders that each hold the mic. The rest of the pipeline (`rec`→16 kHz WAV→`whisper-cli`) was verified healthy; the WAV is correctly 16 kHz mono despite the `can't set sample rate 16000` *input-device* warning, and mic permission was granted — the failure was purely this state-machine desync.
**Fix**: (1) `is_recording()` gained an orphan-adoption fallback: when no live PID file is found, it `pgrep`s for a running `rec -b 16 -c 1 -r 16000 $AUDIO_FILE` and, if found, writes that PID back to `recording.pid` and returns "recording" — so the next press *stops* the orphan instead of stacking a new one. (2) `start_recording()` now `pkill`s any pre-existing recorder on `$AUDIO_FILE` before spawning a fresh `rec`, as a belt-and-suspenders guard so a stray can never accumulate. (3) Fixed `stt-status.sh` reading the PID from `/tmp/claude-stt/recording.pid` while everything else uses `/tmp/para-llm-stt/` — the `REC` status indicator could never have lit. User-side remediation for an already-stuck session: `kill <pid>` the orphaned `rec` once (`pgrep -fl 'rec -b 16'`); after this fix the toggle self-heals.
**File**: `plugins/stt/toggle-stt.sh:38-53` (orphan adoption), `:58-60` (pre-start pkill guard); `plugins/stt/stt-status.sh:6` (PID path)

---

## Known Bug-Prone Areas

### Git Remote Detection
The scripts assume all base repos have an `origin` remote configured. If a repo doesn't have a remote, the clone operation will fail.
**File**: `tmux-new-branch.sh:143-151`, `tmux-new-branch.sh:209-216`

### Branch Name Extraction
The cleanup script extracts branch name by taking everything after the first dash (`${ENV_NAME#*-}`). This works for standard patterns but could fail for edge cases.
**File**: `tmux-cleanup-branch.sh:92`

### Unpushed Commits Detection
The `@{u}` reference requires an upstream branch to be set. New branches without an upstream will show errors (suppressed with `2>/dev/null`).
**File**: `tmux-cleanup-branch.sh:74`, `envs.sh:48`

---

## Notes for Future Bug Entries

When fixing bugs, document:
1. How the bug was discovered (user report, testing, etc.)
2. Steps to reproduce
3. The actual vs expected behavior
4. Any related issues or PRs
