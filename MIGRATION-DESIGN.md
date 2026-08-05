# Migration Design — para-llm voice layer → a single async daemon

**Status:** proposal
**Date:** 2026-07-22
**Author:** design doc for the para-llm-directory voice subsystem
**Companion:** `CODE-REVIEW-2026-07-21.md` (the evidence this is responding to)

---

## 1. Why

The whole-project review found ~65 issues. **Roughly half are one problem wearing many hats:** coordinating ~9 concurrent processes (`stream-watcher`, `stream-step.py`, `stream-synth`, `stream-player`, `stream-rewrite`, `stream-framing`, `stream-keeper`, `stream-status`, `wake-listener`) through **files in `/tmp`, PID files, and Unix signals**. Concretely, that model produced:

- **Orphan / leak bugs** — `kill_tree` SIGTERM to a SIGSTOPped player (guaranteed leak); poll loops that never exit when their pane closes; a `pkill` that stops monitoring across *all* sessions; workers blocked in `edge-tts`/`codex`/`whisper` with unrecorded PIDs that nothing can kill.
- **Race bugs** — a `mkdir` toggle-lock that records its PID non-atomically and falls through *unlocked* (two worker fleets in one spool); `chunks/.next` as a non-atomic read-modify-write shared by three producers; a stale-lock break that runs recap enqueue concurrently with live emission; cwd-keyed pane mapping that can't disambiguate two panes.
- **Supervision gaps** — a keeper that only watches one of the workers, so a synth/player crash = permanent silence, indistinguishable from "working."

None of these is *the* bug. They're the **medium**. A single long-running process with in-memory state, real queues, and one lifecycle owner deletes the entire class at once — no PID files, no `kill_tree`, no `.next`/`.skip`/`.keep` files, no signal gymnastics, no spool `rm -rf` races.

This doc specifies that process, **carries forward the hard-won knowledge** (the ADRs and BUG-020…030 gotchas — the actual value in the current code), and lays out a phased, de-risked port. It is explicit about what the migration does **not** fix.

---

## 2. Goals & non-goals

**Goals**
- Collapse the voice pipeline into **one supervised process** with in-memory state.
- Make the settle/anchor and command-matching logic **unit-testable** (today they're tested by `awk`-ing functions out of shell and `eval`-ing them).
- Preserve every documented behavior and gotcha — this is a re-platform, not a redesign of the algorithm.
- Make the pending features (**listened/unlistened tracking**, multi-pane) natural instead of super-linear in complexity.

**Non-goals**
- Do **not** rewrite the tmux *workspace manager* (`tmux-new-branch`, `tmux-cleanup-branch`, `tmux-command-center`, `install.sh`, `envs.sh`, `scripts/`, `remote-save`). It's a different concern, it's mature, and its bugs are fixable in place (already done for the P0 data-loss set).
- Do **not** attempt to solve the inherent constraints here (feedback, scroll-off, phantom text). They get their own dedicated work — see §6.
- Do **not** change the *user-facing* model: same key bindings, same voice words, same one-bound-pane semantics.

---

## 3. Scope — what migrates, what stays shell

| Component | Today | After |
|---|---|---|
| Speak-mode pipeline (7 workers) | `plugins/tts/stream-*.{sh,py}` | **daemon** |
| Voice commands + dictation | `plugins/stt/wake-listener.sh`, `toggle-stt.sh`, `transcribe.sh` | **daemon** |
| Working-state detection (consumer) | `stream-watcher.sh` hook+footer read | **daemon** (`PaneState`) |
| Toggle / bind / move | `plugins/tts/toggle-stream.sh` | thin shim → **daemon** control socket |
| Status line | `stream-status.sh`, `stt-status.sh` | daemon writes one status file; shim reads it |
| Claude-state **hook writer** | `plugins/claude-state-monitor/hooks/state-tracker.sh` | **stays shell** (it's a Claude Code hook; keep it, just fix its `set -e` guard) |
| Command-center border detector | `state-detector.sh`, `monitor-manager.sh` | stays shell for now (border UX); daemon reads the hook JSON directly for `is_working` |
| Workspace manager | `tmux-*.sh`, `install.sh`, `scripts/`, `remote-save/` | **stays shell** (out of scope) |

The daemon owns the *voice* concern end-to-end. tmux stays at the edges as a subprocess boundary (capture in, send-keys out).

---

## 4. Target architecture

### 4.1 One daemon, in-memory state, asyncio

A single long-running Python process, `para-voiced`, running one `asyncio` event loop. **Python** because the hard parts are already Python (`stream-step.py`), and the whole toolchain is Python-native: `edge-tts` (async), `whisper.cpp` (subprocess or `pywhispercpp`), audio out (`afplay` subprocess or `sounddevice`), tmux (subprocess). No new language to learn; the anchoring/settle logic ports almost verbatim.

State that is currently a pile of files becomes in-memory objects:

| File(s) today | In-memory after |
|---|---|
| `stream.pane`, `active.pane`, `keepalive` | `Supervisor.bound: PaneSession \| None` |
| `anchor.txt`, `prev.txt`, `pending.txt`, `spoken.recent` | fields on `Settler` |
| `chunks/NNNNN.txt`, `chunks/.next` | `asyncio.Queue[Block]` |
| `audio/NNNNN.mp3`, `.skip`, `.keep` | `asyncio.Queue[AudioItem]` (item carries `keep`, `created_at`) |
| `raw/` queue | in-process handoff, no queue file |
| `*.pid` (8 of them) | `asyncio.Task` handles in a `TaskGroup` |
| `framing.lock`, `paused`, `voice.active`, `player.cmd` | `asyncio.Event` / `asyncio.Queue` control messages |

### 4.2 Module map

```
para-voiced (daemon)
├─ Supervisor            # lifecycle, control socket, task restarts (replaces stream-keeper + toggle-stream)
│   ├─ bound: PaneSession│# 0 or 1 active bound pane
│   └─ shadows: [Capture]│# optional background capture of recently-bound panes (tracking feature)
│
├─ PaneSession           # a structured-concurrency group (asyncio.TaskGroup) for one bound pane
│   ├─ capture_task      # poll tmux capture-pane, drive the Settler  (replaces stream-watcher + filter-pane-text)
│   ├─ Settler           # content-anchor + settle + pause-batch      (replaces stream-step.py)  ← port verbatim
│   ├─ scriptify_task    # normalize (+ optional codex rewrite)        (replaces stream-rewrite + normalize)
│   ├─ synth_task        # text → AudioItem (edge-tts, say fallback)   (replaces stream-synth)
│   ├─ play_task         # play in order, pause/seek/freshness         (replaces stream-player)
│   ├─ recap()           # enqueue-ahead recap/digest                  (replaces stream-framing)
│   └─ voice: VoiceIO    # STT transcript → matcher → commands; dictation (replaces wake-listener)
│
├─ PaneState             # is_working(): hook JSON (ADR-011) + footer fallback
├─ TmuxAdapter           # ALL tmux subprocess calls; gotchas encoded once
└─ ControlServer         # unix socket; commands from key-binding shims + internal voice matcher
```

### 4.3 The pipeline as queues

```
tmux capture-pane ──▶ Settler ──blocks──▶ Scriptify ──chunks──▶ Synth ──AudioItem──▶ Player ──▶ afplay
   (capture_task)      (in-proc)          (asyncio.Queue)      (asyncio.Queue)      (asyncio.Queue)
        ▲                                                                                │
        └──────────────── PaneState.is_working() gates the heartbeat ───────────────────┘
```

- **Backpressure** is real: `asyncio.Queue(maxsize=…)` bounds the synth/audio backlog instead of unbounded `audio/*.mp3` files (fixes the "audio grows unbounded during pause" finding — the synth simply awaits a bounded queue).
- **Pause** is `play_paused: asyncio.Event`; `play_task` awaits it. No SIGSTOP, so no "SIGTERM to a stopped process" leak, and pausing the *player* naturally applies backpressure up the chain.
- **Freshness** (the 180s cap, BUG-029) is a comparison on `AudioItem.created_at`; `keep` items are exempt — a boolean on the item, not a `.keep` file the player can miss on rewind.
- **Seek** (forward/rewind) manipulates the play queue and a bounded `deque` rewind buffer in memory — atomic, no `player.cmd` truncation race.

### 4.4 Control plane

The daemon listens on a Unix socket (`$XDG_RUNTIME_DIR/para-voiced.sock`, fallback `/tmp/para-voiced.sock`). A tiny shell shim `para-voicectl` sends one-line commands:

```
Ctrl+b o  →  para-voicectl toggle '#{pane_id}'
```
```
toggle <pane> | pause | play | window | send | forward | rewind | repeat | digest | diagnostic | status
```

The **voice matcher** dispatches the same commands *internally* (no socket round-trip for the STT path). The status line reads a single status file the daemon writes atomically (one writer — kills the "two writers of `@pane_display`" race for the voice indicator).

If the daemon isn't running, `para-voicectl toggle` starts it (systemd `--user` / launchd agent, or a supervised self-fork). One process; no per-pane fleets.

### 4.5 tmux at the edges — the adapter

Every tmux interaction goes through `TmuxAdapter`, which encodes the gotchas **once**:

- `pane_alive(pane)` → `list-panes -a -F '#{pane_id}'` exact match, never `display-message` (BUG-020 gotcha: `display-message -pt <dead>` exits 0).
- `capture(pane)` → `capture-pane -p -S -`; the adapter knows this is a viewport on the alt screen (ADR-010).
- `set_pane_opt(pane, …)` → only ever pane-scoped user options / `window-style`; never `pane-border-style` "per pane" (BUG-021).
- `send_text` / `send_keys` — the inject path with the settle-then-verify logic (BUG-030) lives here.

---

## 5. What the daemon dissolves — mapping the review's architecture cluster

Each of these review findings ceases to exist by construction (not by a fix):

| Review finding | Why it's gone |
|---|---|
| `kill_tree` TERMs a SIGSTOPped player → leak | No signals; pause is an `Event`, shutdown is task cancellation |
| poll loop never exits when pane closes | `capture_task` is cancelled when the session ends; no detached loop |
| `pkill -f state-detector` stops all sessions | No per-pane detector processes; `PaneState` is an in-proc call |
| worker blocked in external call, PID unrecorded → orphan | Tasks aren't PIDs; `TaskGroup` cancels/awaits them; external calls have timeouts |
| whisper-stream no SIGKILL escalation / wedged-alive not restarted | One subprocess the daemon owns with a watchdog + hard kill |
| keeper only watches `watcher.pid` | `Supervisor` restarts *any* failed task; no single-worker blind spot |
| toggle-lock non-atomic + valve proceeds unlocked → 2 fleets | Singleton daemon; "toggle" is a serialized control message |
| `chunks/.next` non-atomic RMW by 3 producers | One `asyncio.Queue`; no counter |
| 180s stale-lock break races recap vs live emission | Recap and live share one queue and one owner; no lock file |
| cwd-keyed pane mapping can't disambiguate | Sessions are keyed by pane id in memory (and env-label for persistence) |
| two writers of `@pane_display` | Daemon is the single status writer |
| `player.cmd` read-then-truncate race | Seek is an in-memory control message |
| one-shot `*.pid`/`*.authored` never swept → stale-file kills | No per-pane files; nothing to sweep or mis-map on renumber |
| orphan-spool sweep can delete all spools | No spools |

That's ~15 distinct findings (and their long-tail variants) retired structurally. **This table is the ROI case for the migration.**

---

## 6. What the daemon does NOT fix (inherent constraints)

Be clear-eyed: these are not shell problems, and a rewrite moves none of them. Each needs its own dedicated solution, scoped separately.

| Constraint | Why a rewrite doesn't help | Dedicated approach |
|---|---|---|
| **Mic hears the speakers** (commands need repeating, even on AirPods) | Acoustic echo — the mic captures the TTS output | AEC (e.g., WebRTC APM / `speexdsp` echo canceller fed the played audio as the reference), or push-to-talk, or a VAD gate that ducks TTS on voice onset |
| **Content scrolls off-screen** (you miss narration) | tmux alt-screen keeps **no scrollback**; polling can't recover what it didn't catch | Continuous background capture of the panes you rotate between (natural in the daemon), or a Claude Code transcript/stream-json tap (couples to the agent — a deliberate, separate bet) |
| **Phantom text** (injected text not in Claude's input model) | `capture-pane` shows the cell grid, not Claude's buffer | Verify-after-submit (already added: box must be empty after Enter), and/or inject only when the pane is idle/ready |
| **whisper mishears short words** | Model accuracy | Bigger wake model, or a constrained grammar / keyword-spotting model for the fixed command vocabulary |

The daemon *does* make the first two **cheaper to attempt** (AEC needs the played-audio reference stream, which the in-process player has; background-capture is just more tasks) — but they are still real work, not free.

---

## 7. Carrying the knowledge forward — ADR / BUG → new design

The value in the current shell is not the code; it's the hard-won gotchas. Every one must land somewhere explicit in the new design (as a preserved invariant, a ported algorithm, or a test), never rediscovered.

| Knowledge | Kind | Where it lives after |
|---|---|---|
| **ADR-009** codex-only summarizer (claude -p retired, metered) | invariant | `scriptify`/`recap` call codex only; config unchanged |
| **ADR-010** poll-and-diff capture (pipe-pane is ANSI noise; hooks have no streaming event) | invariant | `capture_task` polls; documented as the reason it's not event-driven |
| **ADR-011** working-state from Claude Code hook stream + footer fallback | invariant | `PaneState.is_working()` — same logic, in-proc |
| **BUG-019** STT recorder orphan (sox ignores TERM in CoreAudio teardown) | ported | recorder subprocess gets TERM→KILL escalation in `VoiceIO` |
| **BUG-020** alt-screen: viewport-only, content-anchoring not indices | **ported algorithm** | `Settler.find_anchor_end` — port `stream-step.py` verbatim, with its replay fixtures as pytest |
| **BUG-021** `pane-border-style` is window-scoped | invariant | `TmuxAdapter` only sets pane-scoped options |
| **BUG-022** worker startup race (announce-before-ready) | dissolved | no announce/PID handshake; a `TaskGroup` is either up or not |
| **BUG-023** never re-speak (rolling spoken memory) | ported | `Settler.spoken_recent` (in-memory ring) |
| **BUG-024** indicator focus/label (env-name, resolved once) | ported | label resolved once at bind; status file |
| **BUG-025** anchor pinned to tab bar; anchor must not shrink on no-settle | **ported algorithm** | same `Settler` invariants + the "tabbar" regression test |
| **BUG-026** repeat-while-paused enqueues into a frozen player | dissolved | recap sets `play_paused.clear()`; one owner reconciles |
| **BUG-027** send/transcribe recognition (aliases, bursts, annotation strip) | ported | pure `matcher` module, now unit-tested |
| **BUG-028** narrator reads user's queued messages (block-aware filter) | ported | `Settler.filter_speakable` (fix the blank-line dead-code finding en route) |
| **BUG-029** freshness cap vs pause-batch truncation | ported | `AudioItem.created_at` + `keep`; bounded queue removes the root pressure |
| **BUG-030** dictation inject/send race + phantom | ported + hardened | `send_text`: settle-then-verify; still can't fully see the input model (§6) |
| Freshness-skip, catch-up rates, pause-batching, scriptify breaker | ported | `synth`/`scriptify` config, unchanged knobs |
| tmux pane-liveness via `list-panes -a` exact match | invariant | `TmuxAdapter.pane_alive` |

Anything not in this table is either dissolved (§5) or out of scope (§3). **Acceptance criterion for the port: every row here has a corresponding test or a documented invariant in the new code.**

---

## 8. Port order — phased, de-risked, always shippable

Never a big-bang. Each phase leaves a working system.

- **Phase 0 — Scaffold (small).** Daemon process, `TaskGroup` skeleton, `ControlServer` socket, `TmuxAdapter`, `para-voicectl` shim, status file. `toggle-stream.sh` becomes a shim that starts/talks to the daemon. Nothing user-visible changes yet.
- **Phase 1 — TTS pipeline (the bulk).** Port `Settler` (from `stream-step.py`, near-verbatim, with fixtures as tests) → `scriptify` → `synth` → `play` → `recap`. Retire the 6 TTS workers. **Keep `wake-listener.sh` as-is**, talking to the daemon over the socket for pause/window/etc. Ship. This alone dissolves most of §5.
- **Phase 2 — Voice/STT.** Port `VoiceIO`: whisper transcript → `matcher` (unit-tested) → commands; dictation record→transcribe→inject. Retire `wake-listener.sh`, `toggle-stt.sh`. Ship.
- **Phase 3 — Multi-pane + the tracking feature.** `Supervisor.shadows`: background-capture the panes you rotate between; per-pane in-memory "listened marker"; on re-bind, replay the missed backlog (see §11). This is the feature you asked for, now cheap.
- **Phase 4 — Cleanup.** Delete `stream-keeper`, `stream-status`, the spool files, dead helpers (`get-pane-display.sh`), stale docs.

The workspace-manager scripts are untouched throughout.

---

## 9. Testing strategy

The single biggest win after "no more races" is **testability**. Today: `awk` a function out of a `.sh`, `eval` it, poke it. After:

- **`Settler`** — pytest against recorded `capture-pane` fixtures (the alt-screen replays that already exist for BUG-020/023/025). This is the highest-risk port; lock it with the existing regression scenarios *first*.
- **`matcher`** — pure function over transcript lines; the 34-assertion send/transcribe harness from this session becomes a pytest module.
- **`TmuxAdapter`** — mocked subprocess boundary; assert the exact tmux invocations.
- **Pipeline integration** — a fake TTS/whisper backend + a fake pane feeding scripted output; assert what gets "spoken" and when the heartbeat plays.
- **Property/soak** — run the daemon against a recorded session and assert no unbounded queue growth, no task death, clean teardown.

---

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Re-introducing BUG-020/023/025 in the `Settler` rewrite | Port `stream-step.py` **verbatim** first; only refactor behind green fixtures |
| Single daemon = single point of failure | launchd/systemd `--user` supervision + auto-restart; state is cheap to rebuild (it's a live pane, re-anchor on restart) |
| Surviving tmux-server restart / pane renumbering | Key persistent state by **env label**, not pane id (the keeper already learned this) |
| External hangs (edge-tts, codex, whisper) | Port the existing timeouts + circuit breaker; `asyncio.wait_for` per call |
| Scope creep into the workspace manager | Hard scope line (§3); those bugs are fixed in shell separately |
| "Rewrite that never ships" | Phased (§8) — each phase is independently shippable and deletes real fragility |

---

## 11. The listened/unlistened feature falls out

The feature you wanted (never miss narration when you switch panes) is a **Phase 3** natural consequence, not a bolt-on:

- Persist a per-pane **listened marker** (the last-spoken content anchor) in memory on the `Supervisor`, keyed by env label so it survives a re-bind.
- On re-bind, `recap()` gets a *resume mode*: locate the marker in the current capture and replay everything after it **verbatim** as `keep` items, then continue live.
- The honest bound (still true): only what's **still on screen** past the marker is recoverable — alt-screen has no scrollback (§6). The optional `shadows` background-capture of rotated panes closes that gap for the panes you actually use, at the cost of N extra capture tasks — trivial in the daemon, impossible-without-more-processes in the shell.

(Full pre-migration scoping of this feature is in the separate investigation from this session; it maps cleanly onto the daemon.)

---

## 12. Tech choices

- **Python 3.11+** — `asyncio.TaskGroup` (structured concurrency), `EPOCHREALTIME`-free timing, already the language of `stream-step.py`.
- **edge-tts** (async client) — same engine, now awaited, not a subprocess-per-chunk.
- **whisper.cpp** — keep `whisper-stream` as an owned subprocess (transcript over a pipe), or `pywhispercpp` for in-proc; either way one owner, watchdogged.
- **Audio out** — `afplay` subprocess (portable, current) or `sounddevice` (gives the played-audio reference stream that AEC needs later).
- **tmux** — subprocess via `TmuxAdapter`.
- **Supervision** — launchd (macOS) `--user` agent; the shim starts it on first `toggle`.

No heavyweight framework. It's an event loop, a handful of queues, and a subprocess boundary.

---

## 13. Effort & recommendation

- **Phase 0–2** (the daemon + full voice pipeline, retiring 9 workers and the whole §5 cluster): the substantive work — on the order of **1–2 weeks** focused, because the two hardest pieces (`Settler`, `matcher`) **port from existing Python/tested logic** rather than being invented.
- **Phase 3–4** (multi-pane, tracking, cleanup): **a few more days**, and Phase 3 delivers the tracking feature.
- **Inherent constraints (§6):** separate, ongoing — AEC is the highest-value of these and is only *reachable* once the player owns the audio reference stream.

**Recommendation:** greenlight Phase 0–1 as a spike. It's independently shippable, it retires most of the review's architecture cluster, and it proves the `Settler` port against the existing fixtures before committing to the full migration. If Phase 1 lands clean, Phases 2–4 are low-risk continuations. If it doesn't, you've spent a bounded spike and learned the real cost — far cheaper than discovering it three weeks in.

Meanwhile the P0 bug fixes (done) keep the current system usable, and the workspace manager stays exactly where it is.
