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
**Follow-up**: A wedged orphan (`STAT=S`, alive ~24h) survived the in-script `kill` — sox installs its own SIGTERM handler and can ignore TERM during CoreAudio teardown, so adoption alone didn't clear it. Added `kill_recorder()` which sends SIGTERM, waits ~3s, then escalates to an uncatchable `kill -9`. Used by both `stop_and_transcribe` and the pre-start orphan guard (the guard now loops `pgrep`→`kill_recorder` instead of a single `pkill -TERM`). User-side: a stuck pre-fix orphan needs `kill -9 <pid>` once (`kill` alone won't take it).
**File**: `plugins/stt/toggle-stt.sh:38-54` (orphan adoption), `:57-72` (kill_recorder), `:84-91` (escalating orphan guard), `:104-108` (stop path)

### BUG-020: Speak mode (Ctrl+b o) silent on real Claude Code panes
**Date**: 2026-07-14
**Symptom**: Speak mode showed its 🔊SPEAK status indicator but never spoke anything from a pane running Claude Code, even as responses streamed. Worked fine in plain shell panes during development testing.
**Cause**: Two compounding issues. (1) Claude Code's TUI runs on the **alternate screen** (`alternate_on=1`, empty history), so `capture-pane -S -` returns only the ~viewport, and every line **shifts position** as output scrolls — the index-based common-prefix anchor could never hold. (2) The current Claude Code chrome (spinner `✶ Working… (12s · ↓ 6.1k tokens)`, `❯` prompt, `──` separators, live tool timers) was not filtered before diffing, so 4–5 tail lines churned every poll; the churn always exceeded the 3-line tail tolerance, so every poll took the "screen rewrite" resync path and re-anchored past all new text — swallowing everything.
**Fix**: `stream-step.py` rewritten: (1) all churn-prone chrome is dropped **before** diffing (spinners, prompts, separators, tool lines, token counters, keyboard hints), so cur/prev only contain speakable transcript lines; (2) anchoring is now by **content** — the last ≤8 consumed lines are located as a block (last occurrence, progressively shorter suffixes for scroll-off) in each new capture, making the diff immune to line-index shifts from alternate-screen scrolling. Verified by replaying real Claude Code captures and an alt-screen fake-TUI simulator end-to-end.
**Gotcha for future capture work**: `tmux display-message -pt <dead-pane>` exits 0 (falls back to another target) — pane liveness needs `list-panes -a` + exact match (already handled in `stream-watcher.sh`).
**File**: `plugins/tts/stream-step.py`, `plugins/tts/stream-watcher.sh`

### BUG-021: Speak mode turned ALL pane borders magenta
**Date**: 2026-07-14
**Symptom**: Pressing `Ctrl+b o` painted every pane border in the command-center window magenta, not just the bound pane.
**Cause**: `pane-border-style` / `pane-active-border-style` are **window** options; `tmux set-option -pt <pane>` silently stores them at window scope (verified empirically on tmux 3.6a), so "per-pane" border styling colored the whole window.
**Fix**: The toggle only sets `@speak_on` (a real pane-scoped user option); the magenta styling lives in GLOBAL `pane-border-style` / `pane-active-border-style` values as `#{?#{@speak_on},fg=colour201 bold,...}` format conditionals evaluated per pane at draw time — the same pattern as tmux's default active-border conditionals, which the fallback branch preserves.
**File**: `plugins/tts/toggle-stream.sh` (mark_pane/unmark_pane), `install.sh` (global styles)

### BUG-022: Speak mode workers died at startup — status-script race
**Date**: 2026-07-14
**Symptom**: `Ctrl+b o` showed the indicator, but nothing was ever spoken; all three workers were dead with no logs, an intact spool, and `stream.pane` cleared.
**Cause**: `toggle-stream.sh` wrote `stream.pane` first, then `mark_pane` — whose pane-option change triggers a status-line redraw. `stream-status.sh` ran in that window, found `stream.pane` set but `watcher.pid` not yet written, declared the mode stale, and deleted `stream.pane`. Every worker then exited on its first mode check. The race window was widened by mark_pane's tmux round-trips sitting between the two writes.
**Fix**: Three layers: (1) workers and their PID files are set up BEFORE `stream.pane` is announced; (2) each worker waits up to ~2s for the mode file instead of exiting on a not-yet-on mode; (3) the status script only treats `stream.pane` as stale after a 15s grace period.
**File**: `plugins/tts/toggle-stream.sh`, `plugins/tts/stream-watcher.sh`, `plugins/tts/stream-synth.sh`, `plugins/tts/stream-player.sh`, `plugins/tts/stream-status.sh`

### BUG-023: Speak mode looped the same messages repeatedly
**Date**: 2026-07-14
**Symptom**: Speak mode re-spoke the same Claude messages over and over instead of only new text.
**Cause**: When the anchor's newest lines flicker (overlay, re-render, expanding tool output pushing prose out of the viewport and back), the anchor match falls back to an earlier block and still-visible text "re-settles" — every flicker cycle replayed it.
**Fix**: Rolling spoken-lines memory (`spoken.recent`, last 400 lines) in `stream-step.py`: a settled line heard before is never queued again, so anchor confusion degrades to a silent no-op. The anchor still advances over ALL settled lines to track screen position. Suppression/resync events are mirrored to the persistent `/tmp/para-llm-tts/stream.log` (the in-spool events.log dies with the spool on teardown, which had destroyed post-mortem evidence twice).
**Trade-off**: an identical line genuinely repeated within recent memory stays silent.
**File**: `plugins/tts/stream-step.py`

### BUG-024: Speak indicator — frame vanished on focus change; label showed an unknown branch
**Date**: 2026-07-14
**Symptom**: The magenta frame disappeared as soon as another pane was focused, leaving no way to tell which pane was bound; the status chip read "SPEAK accounts-local-identity", a name the user didn't recognize.
**Cause**: (1) Tiled pane borders are SHARED between neighbours; on focus change the active pane's frame overpaints the shared segments, so a border is inherently focus-dependent. (2) The label used `git branch --show-current`, but agents switch branches inside env worktrees mid-session — the chip showed the agent's transient branch, not the env.
**Fix**: (1) The bound pane gets a purple background tint via per-pane `window-style` (verified truly pane-scoped, unlike `pane-border-style`/BUG-021; applied with `set-option -p`, not `select-pane -P`, which can move focus). Focus-independent; `TTS_STREAM_TINT` configures it, empty disables. (2) Label priority is now env dir name > branch > basename, resolved once at enable time.
**File**: `plugins/tts/toggle-stream.sh`, `plugins/tts/stream-watcher.sh`

### BUG-025: Speak mode went permanently silent — anchor pinned to the tab bar
**Date**: 2026-07-14
**Symptom**: `Ctrl+b o` played its recap, then never spoke again as Claude streamed new text. No resyncs, no errors; the watcher just never settled anything (`raw/.next` stayed 1).
**Cause**: Two compounding issues. (1) Claude Code's bottom tab bar (`⧉ coverage · …`) and todo chrome (`✔ …`, `… +77 completed`) weren't filtered, and the tab bar is always the LAST captured line. (2) The anchor-shrink path (`anchor = matched` when nothing settled) let repeated trims whittle the 24-line anchor down to just that tab-bar line — whose last occurrence is the end of the transcript, so "after the anchor" was permanently empty and nothing could ever settle.
**Fix**: `⧉ ✔ ✖ ✗` and leading-`…` lines added to the streaming drops; the anchor no longer shrinks on no-settle polls (find_anchor_end re-trims stale lines each poll anyway — the anchor only advances when text is consumed). Regression case "tabbar" pins the scenario.
**File**: `plugins/tts/stream-step.py`

### BUG-026: "repeat" while paused played beeps but no recap
**Date**: 2026-07-19
**Symptom**: Saying "repeat" played the ack and the preparing Tinks, the recap was generated and enqueued ("enqueued recap: 2 chunk(s)" in stream.log) — but nothing was ever spoken.
**Cause**: The user had said "pause" minutes earlier (player SIGSTOPped, `paused` flag set) and never "play". `do_repeat` didn't check `PAUSED` — it enqueued the recap into a frozen player. The beeps come from the listener/framing processes directly, so they play regardless, which made the mode look alive while its output channel was suspended.
**Fix**: Asking to hear the recap is an unambiguous request for audio: `do_repeat` (also serving "digest") now clears the pause and resumes playback before framing runs.
**File**: `plugins/stt/wake-listener.sh` (do_repeat)

### BUG-027: "send" often didn't fire — and when it did, the tone was inaudible
**Date**: 2026-07-19
**Symptom**: Saying "send" frequently produced no tone, so eyes-free there was no way to know whether the prompt was submitted. Repeating "send" in frustration ("Send. Send. Send. Send.") never triggered either — the words landed inside the dictation as content. Historical log check: every send that *triggered* also sent Enter and acked (94/94), so all silent failures were recognition misses.
**Cause**: Four compounding issues. (1) whisper-stream noise annotations (`[BLANK_AUDIO]`, `[MUSIC PLAYING]`, `(clicking)`) were counted as words, so the strict one-word-while-speaking rule rejected real sends (and `[MUSIC PLAYING]` once *triggered* "play"). (2) Whisper renders clipped "send" as "sent"/"sand" etc.; the word-prefix stem match rejected all of them — the mishearing-alias treatment existed for "transcribe" ("subscrib") but not for the shortest, most collision-prone word in the set. (3) The dictation-close rule required ≤2 words ending in "send", while transcribe-end tolerates ≤6 — a same-segment close ("...make it purple. Send.") or any send-burst could never match. (4) `do_send` was the only command whose ack plays while narration continues (pause/forward/rewind silence the player first), and Pop.aiff is the subtlest of the system sounds — masked.
**Fix**: `normalize()` strips bracketed/parenthesized annotations before matching; "sent" accepted as an exact-word alias (never a prefix — "sentence" must not submit); all-send bursts match in any state except while TTS audio is in flight (narration about the send command must never press Enter — the a028ec9 cascade class); dictation close additionally accepts the raw segment ending with "Send."/"Sent." as its own punctuated sentence (≤12 words); send confirms with its own louder sound (`STT_WAKE_SEND_SOUND`, default Hero.aiff). Verified with a 28-case extraction harness against the real functions.
**File**: `plugins/stt/wake-listener.sh`

### BUG-028: Narrator read the user's own queued messages back to them
**Date**: 2026-07-19
**Symptom**: While a long agent turn ran, speak mode spoke the user's own dictated/queued messages (observed live: a queued "…Send. Send. Send. Send." tail was narrated).
**Cause**: `❯`-prefixed rows are dropped per-line, but long user messages **wrap**, and the wrapped continuation rows carry no marker — a 2–3 space indent that per-line patterns can't distinguish from agent-prose wraps (which must be spoken). The input-box structural cut (BUG-020 era) doesn't cover the queued-messages region above it.
**Fix**: Block-aware `filter_speakable()` in `stream-step.py`: a continuation line belongs to whatever opened its block — `❯`/`⎿` blocks suppress their continuations, `⏺` prose keeps its own; a blank line ends suppression (keeps plain-shell panes mostly narratable). Trade-off: in a bare shell pane, command output that immediately follows a `❯` prompt with no blank line is no longer spoken.
**File**: `plugins/tts/stream-step.py`

### BUG-029: Speak mode truncated responses mid-sentence (freshness cap vs pause-batching)
**Date**: 2026-07-20
**Symptom**: Live narration "talks for a little while and then just stops" — spoken responses are shorter than the agent's actual output and cut off mid-sentence.
**Cause**: The synth AND player both skip any chunk whose audio file is older than `TTS_STREAM_MAX_LAG_SECS` (was 30s in stream mode). The pause-batched emission (c05af95) hands the pipeline a whole turn as ONE block of ~8-10 chunks enqueued at the same instant; the player plays them strictly in order at ~12-14s of speech each, so the block's tail chunks are legitimately 40-120s old by the time they are due — well past a 30s cap — and get skipped. So every multi-chunk turn lost its tail. The 30s cap was tuned for the retired per-sentence trickle (chunks created ~as fast as played); it was never resized when batching concentrated output into blocks. NOT rewrite-shortening (verified: codex passes conversational text through at ~100%) and NOT a settling bug.
**Fix**: Raised the stream-mode default cap to 180s (synth + player + install + live config), sized to fit a full `TTS_STREAM_MAX_PENDING` (1500-char) batch plus margin, so coherent turn-batches play to completion. Catch-up/sprint rates still bound the lag within a batch, and inter-turn quiet drains it. Trade-off: on a genuinely long turn, playback can now lag further behind the screen rather than dropping content — the opposite of the old "freshness beats completeness" default, matching the user's repeated preference for completeness. `0` disables skipping entirely; lower values trade completeness for freshness.
**File**: `plugins/tts/stream-player.sh:24-33`, `plugins/tts/stream-synth.sh:34-39`

### BUG-030: Dictation stranded UNSENT — "send" pressed Enter before large text landed
**Date**: 2026-07-20
**Symptom**: On an idle Claude Code pane, a dictated message sat in the input box never submitted (observed live on thread2: `❯ Yes, pull the 6 defects and 8 golden-updates`). Eyes-free the user reported "send doesn't work… I transcribe things and then they vanish." The wake log confirmed the pattern: large combined dictate+send takes (419, 520, 648 chars) logged `injected` then `Enter sent` in the SAME second, immediately followed by a frustrated repeat "Send." a few seconds later — while small takes (21, 122 chars) submitted on the first try and drew no repeat.
**Cause**: The `send-end` path injected the transcript with `tmux send-keys -l "$text"`, waited a **fixed `sleep 0.4`**, then pressed Enter. Claude Code ingests a big paste asynchronously (materializing it into the input model / a "[Pasted text]" chip); under machine load 0.4s often expired before the text had landed, so the Enter submitted an empty box and the transcript was stranded. The lag scaled with dictation size — exactly matching "big takes fail, small takes work." (Ruled out: inject and Enter always target the same fixed per-listener `$PANE_ID`, so a mid-flow "window" move can't split them — no cross-pane divergence.)
**Fix**: Replaced the blind `sleep 0.4` with `wait_input_ready`, which polls `capture_input_region` — the text between Claude Code's bottom-most pair of `─` rules, prompt/nbsp stripped — and returns only once the input box is non-empty AND unchanged across two reads (done streaming), capped at 2.5s so a busy/streaming pane still submits best-effort. Enter now fires after the whole message has verifiably landed. Also collapse stray CR/LF in the transcript to spaces before injecting so a newline can't fragment the message. Returns in ~0.25s on a settled box (faster than the old fixed sleep). Verified with a function-extraction harness against live panes (non-empty box → text; empty box → returns best-effort at the cap). Window-while-talking, send-burst matching, voice.active ducking, and the "sent" alias are untouched.
**File**: `plugins/stt/wake-listener.sh` (end_dictation, capture_input_region, wait_input_ready, send-end branch)

### BUG-031: New speak loop spoke raw markdown/jargon "not meant to be spoken"
**Date**: 2026-07-23
**Symptom**: The new tail→rewrite→speak prototype loop (`Ctrl+b o`, `prototype/speak_loop.py`) narrated "a ton of technical details clearly not meant to be spoken." The live log's `▶` lines still carried `**bold**`, `` `day_coverage` ``, `expected_count`, and `-` bullet markers — i.e. the raw transcript block, not rewritten speech.
**Cause**: The worker did `narr = rewrite(ch.text, args.model) or ch.text` — on a rewrite failure it fell back to speaking the **raw** agent text (markdown + identifiers), the exact opposite of the loop's purpose. And failures were frequent: `claude -p --model haiku` takes 18–30s on a ~2.5k-char block (measured: 20/26s from project/empty cwd; MCP/CLAUDE.md loading was NOT the cost) and hit the 30s timeout on ~half of large blocks. No API key is set, so the streaming-API path from MIGRATION-DESIGN isn't available — the rewrite is stuck on the slow CLI.
**Fix**: Three changes in `prototype/speak_loop.py`. (1) **Never speak raw** — on failure, retry once with more time, then *skip* the block (silence beats gibberish; text is still on screen). (2) **`split_block()`** breaks a large block into ~700-char pieces on paragraph→sentence boundaries; each rewrites in ~8–14s instead of ~25s, so it rarely times out and pipelines properly (piece N+1 rewrites while piece N plays, and rewrite time < speech duration so lag doesn't grow). (3) **`despeak()`** strips residual markdown (`` ` `` `*` `#` `|` `>` `~`, list markers) as a safety net so TTS never reads a symbol aloud even if a rewrite leaves one. Timeouts raised to 45s primary / 75s retry to absorb `claude -p` variance (an occasional ~34s outlier regardless of size). Verified offline: a 2586-char block → 5 pieces → clean natural speech, no markdown left.
**File**: `prototype/speak_loop.py` (worker, `split_block`, `despeak`)

### BUG-032: New loop — "repeat" played the sticks (no recap) and lost the indicators
**Date**: 2026-07-23
**Symptom**: Under the new speak loop, saying "repeat" produced the "sticks rubbing together" sound but never a recap; and the bottom-right status chip plus the pane-border "🔊 SPEAKING" indicator were gone. User: "repeat should reach back and basically give me framing on where the conversation stands."
**Cause**: Two gaps between the new loop and the old machinery. (1) `wake-listener.sh do_repeat` always launched the OLD `stream-framing.sh` recap worker — its "preparing" beeper is the sticks, and its audio is enqueued into the old player, which isn't running under the new loop, so nothing was spoken. (2) `toggle-speak.sh` set only `@speakloop` + a window tint; it never set `@speak_on` (which drives the magenta border + "🔊 SPEAKING" chip) nor wrote `stream.pane` + `<spool>/watcher.pid` that `stream-status.sh` needs for the bottom-right chip. Worse, `stream-status.sh` deletes `stream.pane` after 15s when no live `watcher.pid` is found — which would also have killed the wake-listener's `mode_active()` gate.
**Fix**: (1) **Native recap** in `speak_loop.py`: a `recapper` thread watches `SPEAKLOOP_REPEAT_FILE`; on touch it pulls the last ~6 transcript blocks (~3.5k chars), asks `claude -p` (new `RECAP_PROMPT`) for a 2–4 sentence spoken "where things stand" update, and plays it via a new `prio_q` the player drains before pending narration. `do_repeat` now, when `SPEAKLOOP_PAUSE_FILE` is set (new loop), just touches the repeat file + acks — no stream-framing, no sticks. Verified: ~8s, clean spoken framing. (2) **Indicators**: `toggle-speak.sh` now points the wake-listener spool at `/tmp/para-llm-tts/<safe>.stream`, writes `watcher.pid` (the speak_loop pid) + `label` there, sets `@speak_on 1`, and writes `stream.pane` — so the existing `stream-status.sh` chip, magenta border, and PAUSED/DICTATE states all light up (and `stream.pane` is no longer reaped as stale).
**File**: `prototype/speak_loop.py` (`recap`, `recapper`, `prio_q`, `player`), `prototype/toggle-speak.sh`, `plugins/stt/wake-listener.sh` (`do_repeat` new-loop branch)

### BUG-033: New loop — voice commands still wired to the broken old system
**Date**: 2026-07-23
**Symptom**: Saying "window" exited the command center. More broadly, several voice commands still drove the retired poll-based stream workers, which aren't running under the new loop — so they either did nothing or hijacked the tmux view.
**Cause**: The wake-listener's command handlers predate the new loop. `do_window` called `tmux select-window`/`select-pane` (yanking the user out of the command-center window) and then launched the OLD `toggle-stream.sh` on the target (starting old-mode there, not moving the new loop — this is what left an orphaned `%7` old-mode listener). `do_forward`/`do_rewind` wrote `$SPOOL/player.cmd` for the old player, a dead no-op. `do_diagnostic` inspected old worker pids + queue dirs (`raw`/`chunks`/`audio`) that don't exist in the new loop, so it reported "all workers dead" while the new loop was healthy.
**Fix**: Audited all 11 commands and got the broken ones off the old system, gated on `SPEAKLOOP_PAUSE_FILE` (set only under the new loop). `do_window`, `do_forward`, `do_rewind` are disabled under the new loop (buzz + log) until reimplemented as new-loop operations — no more view hijack or dead-file writes. `do_diagnostic` gets a new-loop branch reporting honest state: narration loop alive?, voice listener (whisper) alive?, paused?, speech service reachable?. Working commands (transcribe, send, pause, play, text-box, repeat, digest) were already correct — pause/play bridge via the shared pause file; repeat/digest via the recap file (BUG-032); send/clear are tmux-level. Also swept orphaned `stream-framing`/old-mode workers.
**File**: `plugins/stt/wake-listener.sh` (`do_window`, `do_forward`, `do_rewind`, `do_diagnostic` new-loop branches)

### BUG-034: New loop — two panes could be active at once; window/forward/rewind + working heartbeat missing
**Date**: 2026-07-23
**Symptom**: Two panes could both be in speak mode (both purple) at the same time. "window" made a bad sound and did nothing useful. "forward"/"rewind" were disabled. And the "sticks rubbing together" working heartbeat — audible whenever the model is working but not speaking, so silence means "it's your turn" — was gone.
**Cause**: `toggle-speak.sh` was a pure per-pane toggle with no global-owner concept, so starting it on a second pane left the first running (the old poll mode enforced a single owner via `stream.pane`; the new one didn't, and the wake-listener's `cleanup()` never cleared `@speak_on`/`window-style`). window/forward/rewind were stubbed off the old system (BUG-033) but never reimplemented. The heartbeat lived only in the retired `stream-watcher.sh`.
**Fix**: (1) **Single owner** — `toggle-speak.sh stop_pane()` fully tears down ANY pane (loop + wake-listener + whisper + indicators + spool); starting on a pane first evicts the previous `stream.pane` owner, so only one pane is ever purple. (2) **window** — `do_window` cycles narration through the **panes of the bound pane's own window** (the user's agents are 7 panes in one `command-center` window plus a few single-agent windows; the user chose to cycle the command-center panes only). Cycling by tmux *window* was the bug: it only ever hit each window's active pane, so it reached ~4 things and skipped the other command-center panes ("cycles a subset"), and `select-window` jumped out of the command grid ("kills the command view"). Now it lists the current window's panes, picks the next, `select-pane`s it (focus + purple visible in the grid) — **never `select-window`**, so the command view survives. It speaks the target agent's label (instant cue), and launches `toggle-speak.sh` on the target fully detached (subshell double-fork -> reparented to init) so single-owner teardown of the old stack can't kill the launcher; `stop_pane` dropped its `pkill -P "$w"` for the same reason. `SPEAKLOOP_RECAP_ON_START` frames the new pane with a recap. (3) **forward/rewind** — new shared files: forward touches `.skip` (player flushes `audio_q` to jump to the latest), rewind touches `.replay` (controller re-speaks the last block's cached narration via `prio_q`). (4) **Heartbeat** — a thread in `speak_loop.py` reuses the proven signals: Claude's hook state (`/tmp/claude-state/by-cwd/<cwd>.json`; `blocked`/`ended` = silent) with the live footer (`esc to interrupt`) as the arbiter, ducking while speaking / paused / dictating / voice-active. Plays `working-sticks.wav` (sox-generated, reused from old mode). `TTS_STREAM_WORKING_ENABLED=1`.
**File**: `prototype/speak_loop.py` (heartbeat thread, `ensure_sticks`, `hook_state`, `footer_running`, skip/replay channels, `speaking` flag), `prototype/toggle-speak.sh` (`stop_pane`, single-owner, recap-on-start), `plugins/stt/wake-listener.sh` (`do_window`, `do_forward`, `do_rewind`)

---

### BUG-035: New loop — playback "very spotty… talk then pause… not reliable"
**Date**: 2026-07-29
**Symptom**: Narration kept stalling — a few seconds of speech, then a gap, then more speech. Choppy and unreliable throughout, not just occasionally.
**Cause**: Measured the two critical-path costs on this machine: `claude -p --model haiku` ≈ **20s per call** (it boots a full agent per invocation; `claude --version` is 0.06s, so it's the agent loop, not the binary) and `edge-tts` ≈ **5s of fixed overhead per call**. The worker fought both: (1) `split_block` chopped each agent block into ~700-char pieces and ran a **separate 20s rewrite for each, serially** — a 2.1KB block = 3×20s = 60s of rewriting before its audio; (2) it synthesized **per sentence**, so every 2-4s sentence paid ~5s of synth (5s synth for ~2s of audio → guaranteed stutter after every sentence). Single-threaded, the buffer drained on every short block and every sentence boundary.
**Fix**: Three decoupled stages with the costs amortized. (1) **One rewrite per block** — `block_narration` rewrites the whole block in a single `claude -p` call (only genuinely huge blocks pre-split at 2500 chars), and a **fast path** speaks short (<`REWRITE_MIN_CHARS`=160) clean prose directly with no LLM (regex `_CODEY` forces a rewrite on any code/path/markdown residue — correctness-first). (2) **Batch synth** — narration is packed into ~1100-char chunks (`synth_chunks`) and each is **one** edge-tts call, so the 5s overhead amortizes over ~20s of audio (measured 7.5s synth for 7.2s of a 4-sentence block, vs 5s for a single ~2s sentence). Recaps/rewinds (`enqueue_prio`) batch the same way. (3) **Ordered parallel rewrite pool** — a `ThreadPoolExecutor(max_workers=2)`; a submitter feeds blocks (capped `REWRITE_WORKERS+3` ahead) and a collector consumes futures **strictly in submission order**, so the ~20s latency hides behind playback and a buffer builds during the agent's tool pauses without ever reordering narration. Stages: rewrite pool → `synth_q` → single synth thread → `audio_q` → player. Tunables: `SPEAKLOOP_SYNTH_CHARS`, `SPEAKLOOP_REWRITE_WORKERS`, `TTS_STREAM_REWRITE_MIN_CHARS`.
**File**: `prototype/speak_loop.py` (`block_narration`, `synth_chunks`, `_CODEY`, `submitter`/`collector`/`synthesizer` threads replacing the old `worker`, `enqueue_prio` batch synth)

---

### BUG-036: Ctrl+b o still ran the OLD stream mode; its start recap "just sucked"
**Date**: 2026-07-30
**Symptom**: The catch-up spoken on `Ctrl+b o` ("get me up to speed on the previous turn(s)") truncated and was low quality — "it gave a full analysis but it just was not good". None of the new-loop fixes (BUG-031..035) seemed to take effect.
**Cause**: Two things. (1) **The binding was stale.** `install.sh` source binds `o → prototype/toggle-speak.sh` (new loop), but the user's `~/.tmux.conf` (written by an older install) and therefore the running tmux server still had `o → plugins/tts/toggle-stream.sh` — the OLD poll-based mode. Every recent fix landed in a code path no key launched; the user was on the old system the whole time (voice at old `TTS_STREAM_RATE=+10%`, recap from old `stream-framing.sh`). The old framing recap is a **summary hard-capped at `TTS_STREAM_RECAP_CHARS=400`** (~3 sentences) — the truncation. (2) **Even the new loop's recap was weak**: it fed only the last few *assistant text blocks*, tail-truncated to 3500 chars (no user prompt, no turn boundary), and summarized on haiku with a "2-4 sentences" prompt — so it captured only the end of a long turn with no anchor to what was asked.
**Fix**: (1) **Rebind** — updated `~/.tmux.conf` and the live server so `o → toggle-speak.sh` (new loop). Per the user, the old mode is **not** kept as a fallback: removed the `O` binding (live `unbind-key O` + `~/.tmux.conf` + `install.sh`) and killed the lingering old workers/keeper. (2) **Turn-aware catch-up** — `agent_source.recent_events()` now interleaves real user prompts with agent text (skipping tool-results and `<task-notification>`/system-injected user records via `_SYS_USER`); `turn_context()` formats the last 2 turns as `You:` / `Agent:` (≤6000 chars) so the recap anchors on what was actually asked. (3) **Better briefing** — rewrote `RECAP_PROMPT` (concrete "what you asked / what it did / status / what's next", 4-8 sentences, no char cap) and run it on **sonnet** (`SPEAKLOOP_RECAP_MODEL`, ~9s — same latency as haiku, markedly better). (4) **Recap on start default ON** — `toggle-speak.sh` defaults `SPEAKLOOP_RECAP_ON_START=1`, so every `Ctrl+b o` opens with the catch-up. Verified end-to-end on a 20k-record transcript: the briefing correctly says what was asked, what shipped, that it's done, and the one open item it's waiting on.
**File**: `~/.tmux.conf` + `install.sh` (binding: `o`→new, `O` removed), `prototype/agent_source.py` (`recent_events`, `_SYS_USER`), `prototype/speak_loop.py` (`RECAP_PROMPT`, `RECAP_MODEL`, `turn_context`), `prototype/toggle-speak.sh` (recap-on-start default)

---

### BUG-037: Agent's own narration actuated voice commands (mic self-trigger)
**Date**: 2026-07-30
**Symptom**: While the agent was speaking, the narration said "window" and it changed the window — the TTS coming out of the speakers was heard by the mic and fired a voice command. "We never want the agent speech to actuate the workspace."
**Cause**: The wake-listener HAD a self-echo guard — `matches_word`/`matches_send` fall back to a stricter "lone word only" rule while `player_speaking()` is true. But `player_speaking()` only knew the OLD stream mode: it checks `$SPOOL/player.pid` for an afplay child. The NEW loop (`speak_loop.py`) is a single Python process that spawns afplay from a thread and never writes `player.pid`, so `player_speaking()` was **always false** under the new loop, the strict branch never engaged, and a lone narrated "window"/"send" fired.
**Fix**: Content-aware self-echo suppression, because we KNOW the narration text. (1) **Publish what's being said** — `speak_loop.py`'s player writes the current text (last 2 chunks) to `$SPOOL/tts.speaking` and refreshes its mtime every 0.4s while afplay runs (audio queue items became `(path, text)` tuples so the player has the text). (2) **Consume it** — `player_speaking()` now also returns true when `tts.speaking` is fresh (≤1s); new `tts_recently_said(stem)` returns true if that file is fresh within `STT_WAKE_ECHO_COOLDOWN` (4s, absorbs whisper's detection lag) and contains a word starting with the stem. `matches_word`/`matches_send` drop a match when `tts_recently_said` — i.e., the agent is narrating that word. (3) **Repeat-to-force override** — `is_burst` (a clean burst of the same word, e.g. "window window", "send send send") always fires, bypassing the echo guard, since narration never repeats a lone command word. This kills self-triggers of words the agent is speaking while preserving barge-in for any OTHER word, and gives a reliable manual override (say it twice). Verified with a matcher harness: narrated "window" → lone "window" dropped, "window window" fires, lone "window" fires when narration isn't saying it or once the file goes stale.
**File**: `prototype/speak_loop.py` (`publish_speaking`, `tts.speaking`, `(path,text)` audio items), `plugins/stt/wake-listener.sh` (`player_speaking`, `tts_recently_said`, `is_burst`, `matches_word`, `matches_send`)

---

## Known Bug-Prone Areas

### Live narration starves during long tool-heavy agent turns
During a long single turn with dense tool calls, the viewport is dominated by
tool chrome and redraws; prose scrolls off before it can settle (2 identical
polls) and the pause-batch quiet window rarely arrives. The filtered capture
can flap between ~1 and ~15 lines, so nothing settles and the stream goes
quiet for minutes even though the pipeline is healthy ("agent is slow or audio
is broken" reports). Recap/digest ("repeat") still works — it reads the pane
directly. A real fix likely needs a capture-stability heuristic or a
scrollback-aware capture. The "diagnostic" voice command reports
workers/queues/network to distinguish this from genuine breakage.

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
