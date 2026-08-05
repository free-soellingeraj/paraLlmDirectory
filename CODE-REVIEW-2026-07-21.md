# para-llm-directory — Whole-Project Code Review

**Date:** 2026-07-21
**Branch:** `stream-playback-2` (== `origin/main`, commit `ff397c4`)
**Method:** 5 parallel read-only review agents, one per subsystem, each cross-checked against the documented bug history (`bugs-fixed.md`, `architectural-decisions.md`) to separate new defects from already-handled gotchas.
**Scope:** ~3,800 lines of shell + Python across `plugins/tts/`, `plugins/stt/`, `plugins/claude-state-monitor/`, `plugins/remote-save/`, top-level `tmux-*.sh` / `install.sh`, and `scripts/`.

## Verdict

~65 findings. **No crash-level / unconditional-corruption bugs.** But: **1 critical data-loss path**, ~10 high-severity, and — the important structural result — **roughly half the findings are one problem in many disguises: coordinating ~9 processes through files, PID files, and Unix signals.** That cluster is the concrete, evidence-backed case for migrating the core to a single long-running daemon.

| Bucket | Count | Nature |
|---|---|---|
| Data-loss / destructive | 6 | Contained bugs — fix now regardless of rewrite |
| Send / dictation reliability | 7 | Explains the recent "send doesn't work" pain — fix now |
| Quick correctness wins | ~8 | One-liners |
| Architecture symptoms (process coord / races / supervision) | ~30 | A daemon rewrite dissolves the whole class |
| Inherent constraints | ~4 | Neither fix nor rewrite removes these |

---

## 🔴 P0 — Data loss & destructive (fix first, independent of any rewrite)

- **`tmux-cleanup-branch.sh:135` [CRITICAL] — deletes unpushed commits silently.** The "unpushed?" guard is `git log @{u}..`; a fresh branch (never pushed) has no upstream, the command errors, is silenced, `unpushed=0`, and the warning is skipped — env `rm -rf`'d after only the generic confirm. Also never checks `git status` for uncommitted/untracked work. **Fix:** treat `@{u}` failure as "cannot verify → warn/block"; additionally block when `git -C "$clone_dir" status --porcelain` is non-empty.
- **`tmux-cleanup-branch.sh:194` [HIGH] — kills the wrong env's pane.** `[[ "$pane_path" == "$ENV_DIR"* ]]` with `ENV_DIR=".../proj-a"` also matches `.../proj-a-b/...`, killing the running agent pane of `proj-a-b` when cleaning `proj-a`. **Fix:** compare against `"$ENV_DIR"/*` or exact-equal.
- **`tmux-cleanup-branch.sh:177` [MEDIUM] — the safer Method-1 pane lookup reads the wrong state-file path** (`/tmp/tmux-command-center-state-$SESSION` vs the installed `$PARA_LLM_ROOT/recovery/command-center-state-$SESSION`), so it always no-ops and **forces the buggy prefix-match (above) to run every time.** **Fix:** derive the path via the bootstrap file like the writer does.
- **`tmux-new-branch.sh:432,438` [HIGH] — `rm -rf "$ENV_DIR"` on clone failure can delete a pre-existing env with work.** The attach path `mkdir -p "$ENV_DIR"` without the existence guard the new-branch path (`:498`) has; a failed second-repo clone nukes the whole dir. **Fix:** only remove dirs this invocation created; refuse to reuse an existing `ENV_DIR` in attach.
- **`install.sh:380` [HIGH] — hooks merge clobbers your existing hooks.** `jq '.hooks = (.hooks // {}) + $new'` replaces each event array wholesale, so pre-existing `PreToolUse`/`Stop`/etc. hooks are lost on install (only a `.backup` remains). **Fix:** concat arrays per event: `reduce ($new|to_entries[]) as $e (.; .hooks[$e.key] = ((.hooks[$e.key] // []) + $e.value))`.
- **`install.sh:406` [MEDIUM] — managed-block `sed` range deletes to EOF if the end marker is absent** (interrupted prior install). **Fix:** require both markers before the range delete.
- **`toggle-stream.sh:175-181` [LOW] — orphan-spool sweep deletes *all* `*.stream` dirs if a transient `tmux list-panes` returns empty.** **Fix:** skip the sweep when `live_panes` is empty / the tmux call failed.

## 🟠 P0 — Send / dictation reliability (this explains the recent pain)

- **`wake-listener.sh` `do_send` (listening branch, ~765) [HIGH] — the BUG-030 fix was applied only to the combined "send-end" branch, NOT the common "transcribe → then say send" path.** That path presses Enter with no `wait_input_ready`, so large dictations still strand on the flow actually used. **Fix:** gate the listening-state `do_send` behind `wait_input_ready` (or move the wait into `do_send`).
- **`wake-listener.sh` `wait_input_ready`/`capture_input_region` (~497-534) [HIGH] — validates the rendered viewport, not Claude's committed input model, so the "phantom text" case is undetectable, and `do_send` chimes the Hero "sent" sound regardless of whether anything submitted.** The one signal you can't miss can be false. **Fix:** re-verify the box is *empty* after Enter (submission cleared it) before chiming success; buzz if text remains.
- **`wake-listener.sh:742,811` [HIGH] — "transcribe won't start."** The echo-guard tracks only the `transcri` stem, but matching also accepts the `subscrib` mishearing — so "transcribe" heard as "subscribe" ends the dictation it just started (its own echo), yielding ~0s audio → "no speech" buzz. **Fix:** suppress the full alias set in the echo guard.
- **`wake-listener.sh:221,237-252` [MEDIUM] — "send" is a prefix match**, so "sending"/"sends" in a ≤2-word remark presses Enter. **Fix:** match "send"/"sends" as whole words, not `send*`.
- **`wake-listener.sh:221,765` [MEDIUM] — send/sent echo-guard mismatch → double Enter** (a lingering "sent" echo fails the "send"-stem guard and re-fires). **Fix:** guard against the alias set.
- **`wake-listener.sh:482-489` [LOW] — the "sent" chime plays before/independent of the `send-keys Enter` result.** **Fix:** chime only after Enter succeeds.
- **`wake-listener.sh:716-725` [LOW] — `do_clear` can send two `Ctrl+C` to an empty box → exits the Claude REPL** (the "never twice" claim rests only on the echo guard; no not-empty check). **Fix:** capture the input region and only send `C-c` when non-empty.

## 🟡 P1 — Quick correctness wins (mostly one-liners)

- **`filter-pane-text.sh:16` [MEDIUM] — BRE alternation `\(Yes, continue\|No, quit\)` is dead on macOS `sed`**, so the trust-dialog's numbered options leak into speech. **Fix:** two plain patterns, or use `grep -E`/`perl`.
- **`stream-step.py:145-159` [MEDIUM] — the block-suppression blank-line reset is dead code** because `filter-pane-text.sh` strips blanks upstream; on plain-shell / non-`⏺` panes all prose after the first `❯` is suppressed forever. **Fix:** preserve blanks into `stream-step.py`, or reset `suppress` on a real boundary.
- **`hooks/state-tracker.sh:11,33` [MEDIUM] — `set -euo pipefail` with no guard aborts the hook on any `jq`/tmux hiccup, on every PreToolUse/PostToolUse** (noisy hook errors; empty stdin writes `/tmp/claude-state/.json`). **Fix:** `command -v jq` guard, drop `set -e` (or `trap 'exit 0' EXIT`), default `SESSION_ID=unknown`.
- **`state-detector.sh:82` [MEDIUM-HIGH] — `is_claude_working` greps `tail -3` of the *raw* capture, missing the `esc to interrupt` footer → false "ready" while working.** The correct strip-blanks-then-`tail` pattern already exists in `stream-watcher.sh:footer_running`; port it.
- **`filter-pane-text.sh:10-11` [LOW] — `/ctrl.*enter/d`, `/shift.*tab/d` are unanchored substring deletes** that swallow legit prose ("press ctrl to enter…"). **Fix:** anchor to the keyboard-hint chrome.
- **`transcribe.sh:41-42` [LOW] — `MODEL_DIR="${PARA_LLM_ROOT:?…}"` is evaluated before the `STT_MODEL_PATH` override**, so a caller with `STT_MODEL_PATH` set but no `~/.para-llm-root` aborts under `set -u`. **Fix:** compute `MODEL_DIR` lazily.
- **`pane-monitor.sh:59` [LOW] — `tmux has-session -t "%5"` treats a pane id as a session name → always "Session ended"** (also appears to be dead/legacy code). **Fix:** `list-panes -a -F '#{pane_id}' | grep -qxF`.

---

## 🏗️ Architecture symptoms — the rewrite case, quantified

Roughly half the review is one problem wearing many hats: **coordinating ~9 concurrent processes through files, PID files, and Unix signals.** A single async daemon (in-memory state, real queues, one lifecycle owner) dissolves the whole class at once.

### Orphan / process-leak cluster
- **`tts-lib.sh:19-26` + `stream-watcher.sh:97` + `toggle-stream.sh:141` [HIGH] — `kill_tree` sends SIGTERM to a SIGSTOPped (paused) player, which stays alive until CONT → guaranteed leaked player on teardown-while-paused** (`teardown_dead_pane` deletes `player.pid` before the wake-listener can CONT it; if `STT_WAKE_ENABLED=0`, every paused teardown leaks). **Fix:** `kill -CONT` before `kill` (or escalate to `-9`) in `kill_tree`.
- **`state-detector.sh:245-248` [HIGH] — the poll loop never checks its pane still exists → runs forever after the pane closes** (0.3s polling + `capture-pane` each tick), reaped only by the global `pkill`. **Fix:** verify pane liveness each iteration and exit.
- **`monitor-manager.sh:136` (via `:78`) [HIGH] — `pkill -f "state-detector.sh"` is server-global**, so any Command Center attach/detach stops monitoring in *all* sessions. **Fix:** kill only the PIDs recorded in `$PID_DIR` for this window.
- **`toggle-stream.sh:222-241` + `:141` [MEDIUM] — spawn→PID-record gap; a worker blocked in an external call (edge-tts ~20s, codex ~60s, whisper mic) with an unrecorded PID is never SIGTERMed on teardown, and `rm -rf "$spool"` yanks its files mid-flight** (the BUG-019 orphan class, unaddressed for the speak-mode fleet). **Fix:** record PID before backgrounding; on stop, `pgrep -f` the worker scripts scoped to the spool and kill survivors.
- **`toggle-stream.sh:141` [LOW-MEDIUM] — the stop kill-list omits `working-sound.pid`** (which the watcher's teardown includes), so a desynced `watcher.pid` orphans the sticks/cricket loop forever. **Fix:** add `working-sound.pid` for parity.
- **`wake-listener.sh:161-162` [MEDIUM] — whisper-stream cleanup does TERM only, no SIGKILL escalation** (a wedged CoreAudio client survives and holds the mic → next enable stacks a second whisper). **Fix:** same TERM-then-KILL escalation as `kill_recorder`.
- **`wake-listener.sh:838-845` [MEDIUM] — restart-on-death only checks `kill -0`**, so a wedged-but-alive whisper-stream is never restarted → listener silently goes deaf. **Fix:** also detect log staleness and restart.
- **`toggle-tts.sh:197-205` + `tts-lib.sh:29-63` [MEDIUM] — one-shot per-pane files are never swept**, so a tmux-server restart (renumbers panes, `/tmp` survives) maps a stale `<id>.authored.txt` / `<id>.pid` onto an unrelated pane → wrong briefing, or `kill_tree` on a recycled PID kills an unrelated process tree. **Fix:** startup liveness sweep + validate the stored PID's command before kill.

### Race / shared-state cluster
- **`toggle-stream.sh:78-92` + `toggle-tts.sh:88-103` [HIGH] — the `mkdir` toggle-lock records its PID non-atomically, and the `tries>100` valve falls through and proceeds *unlocked*** → two full worker fleets in one spool (first fleet orphaned; audio doubles) / overlapping one-shot playback. **Fix:** make lock ownership atomic; on valve-timeout show "busy" and exit, don't proceed.
- **`stream-step.py:280-288` vs `stream-framing.sh:149-160` [MEDIUM] — the 180s stale-lock break can run recap enqueue concurrently with live emission**, two producers doing non-atomic RMW of `chunks/.next` → clobbered chunk or stale counter (orphaned/duplicated audio, or a gap that deadlocks the strict-order synth). Masked today only because codex is capped ~60s. **Fix:** framing must re-verify it holds the lock before enqueuing; the stale threshold must exceed the summarize budget.
- **`stream-framing.sh` / `stream-rewrite.sh` / `stream-step.py` [LOW-MEDIUM] — `chunks/.next` is a non-atomic read-modify-write shared by three producers** with no real mutual exclusion (safe only by current mode arrangement). **Fix:** one owner for `chunks/` writes, or an atomic allocator.
- **`state-detector.sh:54-71` + `state-tracker.sh:121` [HIGH] — cwd-keyed pane mapping can't disambiguate two live panes sharing a cwd** (split pane, two clones at one path) → last-writer-wins → wrong-pane border updates. **Fix:** key by session/pane identity.
- **`state-tracker.sh:121` [MEDIUM] — auto-create matches the pane via `grep "|${CWD}$"` (BRE, no `-F`)**, so `.`/`+`/`[` in a path is treated as regex → wrong pane. **Fix:** `grep -F` / exact field compare.
- **`state-detector.sh:210-219` vs `state-tracker.sh:186-194` [MEDIUM] — two uncoordinated writers of `@pane_display`, and the detector only re-renders on a *state change*** → a wrong/stale border can persist indefinitely. **Fix:** detector reconciles unconditionally.
- **`stream-watcher.sh:271-282` [LOW] — `trigger_digest`'s "already running?" guard is a TOCTOU on `framing.pid`** → two ticks can double-spawn framing. **Fix:** claim atomically (`mkdir` lock).
- **`stream-player.sh:69-73` [LOW] — `handle_cmd` reads then truncates `player.cmd` non-atomically** → a rapid seek command can be lost. **Fix:** `mv` the command file and read that.
- **`stream-keeper.sh:82-90` + `toggle-stream.sh` [MEDIUM] — a keeper revive races the user's explicit disable and can resurrect the mode + re-arm `keepalive`.** **Fix:** re-check `keepalive` inside the toggle lock before revive; don't re-arm persistence on revive.

### Supervision gap
- **`stream-keeper.sh:44-51` [MEDIUM] — the supervisor only checks `watcher.pid`; a crash of synth/player/rewrite/framing silently stalls audio forever** (indistinguishable from the known starvation case). **Fix:** health-check all worker PIDs and re-spawn, or tear down and revive the whole mode.
- **`monitor-manager.sh:31` [MEDIUM] — reads the Command Center state-file at the wrong path** → always falls back to path-derived project/branch (mis-splits dashed dir names). **Fix:** resolve via the bootstrap path like the writer.

## ⛔ Inherent constraints — neither fix nor rewrite removes these

- **Firehose starvation** — `stream-step.py:233-240` resync re-anchors and speaks nothing for the skipped region; **content that scrolls off is unrecoverable** because Claude Code's TUI is on the tmux alt-screen with no scrollback. Needs continuous capture or a Claude Code transcript tap.
- **Phantom text root** — the terminal cell grid and Claude's committed input model can diverge; you cannot fully detect it from `capture-pane`. Needs verify-after-submit or a different input channel.
- **(From the working session, outside these files)** acoustic mic↔speaker feedback (commands need repeating even on AirPods) and whisper accuracy on short words — hardware/model, not code.

---

## Appendix — full findings by subsystem

### A. tmux orchestration / installer / remote-save
1. [CRITICAL] `tmux-cleanup-branch.sh:135` — unpushed/uncommitted work deleted (no-upstream guard fails).
2. [HIGH] `tmux-cleanup-branch.sh:194` — pane-kill prefix match kills `X-…` when cleaning `X`.
3. [HIGH] `install.sh:380` — hooks merge `+` replaces user's existing hooks.
4. [HIGH] `tmux-new-branch.sh:432,438` — `rm -rf ENV_DIR` on clone failure deletes pre-existing env.
5. [MEDIUM] `tmux-cleanup-branch.sh:177` — Method-1 pane lookup reads wrong state path (dead code → forces #2).
6. [MEDIUM] `tmux-cleanup-branch.sh:208-210` — window-kill `grep " $BRANCH$"` suffix/regex match kills unrelated windows.
7. [MEDIUM] `tmux-cleanup-branch.sh:160` — `${ENV_NAME#*-}` wrong for hyphenated project names (window leak).
8. [MEDIUM] `install.sh:406` — managed-block `sed` range deletes to EOF if end marker absent.
9. [MEDIUM] `scripts/para-llm-save-state.sh:31` — invokes a script `install.sh:320` deletes → CC not exited before save → degraded restore.
10. [MEDIUM] `remote-restore-full.sh:110,120,136` — windows targeted by name, ambiguous for duplicates → wrong pane.
11. [MEDIUM] `backends/ssh.sh:42,54,74` — `REMOTE_DIR` single-quoted into remote command → injection.
12. [LOW] `install.sh:481-485,514` — `set -ga status-right` accumulates duplicates on reinstall.
13. [LOW] `tmux-command-center.sh:156` — window name in single-quoted `run-shell` → injection.
14. [LOW] `backends/ssh.sh:22-31` — SSH key path unquoted in `-e` string → breaks on spaces.
15. [LOW] `pane-monitor.sh:59` — `has-session` on a pane id → always "Session ended"; dead code.

### B. State monitor & hooks
1. [HIGH] `monitor-manager.sh:136` — server-global `pkill` stops monitoring across all sessions.
2. [HIGH] `state-detector.sh:245-248` — poll loop never exits when pane closes → orphan + CPU.
3. [MEDIUM-HIGH] `state-detector.sh:82` — raw `tail -3` misses the footer → false "ready".
4. [HIGH] `state-detector.sh:54-71` + `state-tracker.sh:121` — cwd mapping can't disambiguate two panes → wrong-pane updates.
5. [HIGH] `hooks/state-tracker.sh:11,33` — `set -euo pipefail` aborts hook on jq/tmux hiccup every tool call; empty stdin → `/tmp/claude-state/.json`.
6. [MEDIUM] `state-tracker.sh:121` — auto-create `grep` treats cwd as BRE regex → wrong pane.
7. [MEDIUM] `monitor-manager.sh:31` — reads CC state file at wrong path → path-derived fallback mis-splits dashed dirs.
8. [MEDIUM] `state-detector.sh:74` vs `:227-233` — mapping keyed by startup cwd, cleanup by current cwd; PROJECT/BRANCH frozen → stale.
9. [MEDIUM] `state-detector.sh:210-219` vs `state-tracker.sh:186-194` — two uncoordinated `@pane_display` writers; detector only re-renders on state change → stale border.
10. [MEDIUM-LOW] `tmux-status.sh:47-68` — aggregate counts include stale/collided `by-cwd` files → phantom sessions.
11. [LOW] `state-detector.sh:112-121` — `is_claude_session` scans only `-S -30` → busy pane misclassified as terminal → pinned "Working".
12. [LOW] `get-pane-display.sh` — dead display-*file* path; README/ADR-007 stale (border renders from `@pane_display`).

### C. TTS control & library
1. [HIGH] `toggle-stream.sh:78-92` + `toggle-tts.sh:88-103` — non-atomic toggle-lock + valve-timeout proceeds unlocked → double worker fleet / overlapping playback.
2. [MEDIUM] `filter-pane-text.sh:16` — BRE alternation dead on macOS `sed` → trust-dialog options leak.
3. [MEDIUM] `toggle-stream.sh:222-241`/`:141` — spawn/PID-record gap → orphaned worker blocked in external call (BUG-019 class).
4. [MEDIUM] `toggle-tts.sh:197-205` + `tts-lib.sh:29-63` — one-shot files never swept → pane renumber → wrong briefing / kill unrelated process.
5. [MEDIUM] `stream-keeper.sh:82-90` — keeper revive races user disable → resurrects mode + re-arms keepalive.
6. [LOW-MEDIUM] `toggle-stream.sh:141` — stop kill-list omits `working-sound.pid` → orphaned chirp loop.
7. [LOW-MEDIUM] `voice-script.sh:37-48` — ambiguous cwd falls back to `$TMUX_PANE` → wrong pane.
8. [LOW] `toggle-stream.sh:175-181` — orphan sweep deletes all spools if `live_panes` empty.
9. [LOW] `filter-pane-text.sh:10-11` — unanchored `/ctrl.*enter/`, `/shift.*tab/` drop legit prose.
10. [LOW] `toggle-tts.sh:439-449` — subshell removes PID file before parent writes → stale PID / leaked slot.
11. [LOW] `stream-watcher.sh:271-282` — `trigger_digest` TOCTOU on `framing.pid`.
12. [LOW] `filter-pane-text.sh:6` — CSI regex omits param bytes `: < = >` (defensive only).

### D. STT / voice commands
1. [HIGH] `wake-listener.sh:742,811` — echo-guard misses `subscrib` alias → transcribe's own echo ends dictation instantly.
2. [HIGH] `wake-listener.sh` `do_send` (listening branch) — no `wait_input_ready` → BUG-030 reopened on the primary transcribe-then-send flow.
3. [HIGH] `wake-listener.sh:497-534` — `wait_input_ready` validates the viewport not the input model → can't detect phantom, chimes success falsely.
4. [MEDIUM] `wake-listener.sh:221,765` — send/sent echo-guard gap → double Enter.
5. [MEDIUM] `wake-listener.sh:161-162` — whisper-stream cleanup TERM only, no SIGKILL escalation.
6. [MEDIUM] `wake-listener.sh:838-845` — restart-on-death only `kill -0` → wedged-alive whisper never restarted (silently deaf).
7. [MEDIUM] `wake-listener.sh:221,237-252` — "send" prefix match → "sending"/"sends" false-submit.
8. [MEDIUM] `toggle-stt.sh:164` — empty target-pane file → injects into whatever pane is current.
9. [LOW/MEDIUM] `wake-listener.sh:728-734` — "last two lines joined" comment but loop matches a single line → multi-word "text box" split across segments missed.
10. [LOW] `wake-listener.sh:146-155` — `normalize` annotation strip handles only balanced brackets → unterminated `[MUSIC PLAYING` → "playing" can trigger.
11. [LOW] `wake-listener.sh:716-725` — `do_clear` double `Ctrl+C` on empty box → exits REPL.
12. [LOW] `wake-listener.sh:482-489` — "sent" chime plays before/independent of Enter result.
13. [LOW] `transcribe.sh:41-42` — `MODEL_DIR` evaluated before `STT_MODEL_PATH` override → aborts under `set -u`.
14. [LOW] `wake-listener.sh:351-446` — `end_dictation` runs `transcribe.sh` (≤120s) synchronously in the event loop → blocks mode/pause checks; injects even if mode toggled off mid-transcription.

### E. TTS streaming core
1. [HIGH] `tts-lib.sh:19-26` + `stream-watcher.sh:97` + `toggle-stream.sh:141` — `kill_tree` TERMs a SIGSTOPped player → leaked paused player (guaranteed in `teardown_dead_pane`).
2. [MEDIUM] `stream-step.py:145-159` — block-suppression blank-line reset is dead code → plain-shell / non-`⏺` prose suppressed forever.
3. [MEDIUM] `stream-keeper.sh:44-51` — supervisor only checks `watcher.pid` → synth/player/rewrite/framing crash = permanent silence.
4. [MEDIUM] `stream-step.py:280-288` vs `stream-framing.sh:149-160` — 180s stale-lock break races recap enqueue vs live emission on `chunks/.next`.
5. [MEDIUM] `wake-listener.sh:123-136` + `stream-synth.sh:76-148` — `pause` doesn't SIGSTOP the synth → `audio/` grows unbounded during a long pause.
6. [LOW-MEDIUM] `chunks/.next` — non-atomic RMW shared by three producers.
7. [LOW] `stream-player.sh:69-73` — `player.cmd` read-then-truncate race → seek lost.
8. [LOW] `stream-step.py:162-180` — `find_anchor_end` O(n·anchor²) over full `-S -` scrollback every 0.4s → CPU on plain-shell panes.
9. [LOW] `stream-step.py:402-419` — crash between chunk emit and `.next` update → re-emit.
10. [LOW] `stream-player.sh:136-139` — afplay-kill-for-seek counts interrupted chunk as played → rewind off-by-one.
11. [LOW] `stream-player.sh:80-83` — `back` doesn't restore the `.keep` marker → rewound recap freshness-skip-eligible.
12. [LOW-documented] `stream-step.py:233-240` — resync drops the skipped region (known firehose starvation).

---

## Recommendation

1. **Do the P0 buckets now** — data-loss safety + send-reliability are contained, mostly one-liners, and worth fixing regardless of the rewrite decision. Start with `tmux-cleanup-branch.sh:135` (the commit-eater).
2. **Let the architecture cluster drive the rewrite decision** — ~30 findings a single daemon deletes wholesale (no PID files, no `kill_tree`, no file-based `chunks/.next`, one lifecycle owner). This review *is* the ROI case.
3. **Scope the inherent constraints separately** — AEC / push-to-talk for feedback, background-capture or a transcript tap for scroll-off, verify-after-submit for phantom text. A rewrite doesn't cover these.
