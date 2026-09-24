# Hands-Free / Eyes-Free + the Window Manager

**Audience:** an LLM (or engineer) that needs to reason about, modify, or debug
this system without reading all ~7,600 lines of shell and Python first.

**Scope:** how para-llm-directory's *window manager* (tmux window/pane
orchestration: `Ctrl+b c`, `Ctrl+b v`, the state monitor, the indicator layer)
and its *hands-free / eyes-free* (HFEF) stack (`Ctrl+b o`: continuous
narration + always-on voice commands) are built, and — the part that is easy to
miss — the specific places where the two are **load-bearing for each other**.

Everything below is derived from the code on branch `explain-hfef-prompt` at
commit `fb0a3b6`. Where a claim is inference rather than something written in
the code, it is marked **[inferred]**.

---

## 0. The one-paragraph version

para-llm-directory runs N coding agents (Claude Code or Codex) in parallel, one
per git clone, one per tmux pane. The **window manager** collapses those panes
into a single "command center" window, gives the *focused* agent a large main
pane, and paints each pane's border with that agent's live state (working /
waiting / blocked), sourced from Claude Code's own hooks. The **HFEF stack**
binds exactly one of those panes at a time and turns it into a voice terminal:
it tails that agent's JSONL transcript, rewrites each completed prose block into
speech with an LLM, and speaks it; simultaneously a always-on whisper listener
watches for single-word commands (`transcribe`, `send`, `pause`, `window`, …).
The two systems meet at three seams: **the tmux pane id is the shared primary
key**, **the `window` voice command drives the window manager's focus/layout
machinery**, and **the window manager's "focused agent gets the big pane" rule
is what makes voice dictation and send-confirmation work at all**, because those
read the *rendered* input box out of the pane.

---

## 1. Ground layer: the environment model

Everything else assumes this layout. Created by `tmux-new-branch.sh` (`Ctrl+b c`).

```
~/code/
├── MyProject/                       # base repo (no dashes in the name)
├── para-llm-directory/              # this tool ($PARA_LLM_ROOT, via ~/.para-llm-root)
└── envs/
    └── MyProject-feature-x/         # one env == one feature branch
        └── MyProject/               # the clone; the agent's cwd
            └── .para-llm/
                ├── repl             # "claude" | "codex"
                ├── transcript.log   # raw pane bytes (tmux pipe-pane)
                └── handoff.md       # written when switching REPL products
```

Invariants worth holding onto:

- **One env == one clone == one branch == one tmux pane running one agent.**
- The env directory name is `{Project}-{Branch}`; the substring after `envs/`
  and before the next `/` is used *everywhere* as the human label for that
  agent (status chip, spoken hand-off announcement, pane border).
- `~/.para-llm-root` is a bootstrap file containing the absolute path to this
  repo. Nearly every script reads it to find `$PARA_LLM_ROOT/config`.
- `.para-llm/transcript.log` (raw pane bytes via `pipe-pane`) is **not** what
  the speak loop reads. The speak loop reads the *agent framework's own* JSONL
  session file. Two different transcripts; don't conflate them.

`create_feature_window()` (`tmux-new-branch.sh:26`) branches on whether the
command center is currently open:

- **not in command center** → plain `tmux new-window -n "$branch"`.
- **in command center** → `new-window`, then `join-pane -s <new> -t
  command-center -h`, append a row to the command-center state file, seed
  `@pane_display`, and launch a `state-detector.sh` for the new pane.

---

## 2. The window manager

### 2.1 Command center: `Ctrl+b v` → `tmux-command-center.sh`

It is a **toggle with three states**:

| Condition | Action |
|---|---|
| CC window doesn't exist | `create_command_center` |
| CC exists, you're not in it | `select-window` to it |
| CC exists, you're in it | `restore_command_center` (tear down) |

**Create** (`tmux-command-center.sh:181`):

1. `discover_windows` lists every window in the session except `command-center`
   itself, emitting `pane_id|window_name|session:index|project`.
2. Create the `command-center` window; remember the throwaway shell pane it
   comes with.
3. For each discovered pane: `tmux join-pane -s <pane> -t command-center -h`.
   **This physically moves the pane** — the original window disappears (tmux
   kills a window when its last pane leaves). Append `pane_id|name|origin|project`
   to the state file.
4. Kill the throwaway pane.
5. `main-pane-width` ← `$PARA_CC_MAIN_WIDTH` (default `60%`); `select-layout
   main-vertical`.
6. `pane-border-status top`, and a **window-scoped** `pane-border-format` that
   renders `@pane_display`.
7. Seed each pane's `@pane_display`, select pane 0, install the focus hook
   (`tmux-cc-focus.sh enable`), start the state monitor.

**State file** — the only thing that makes teardown non-destructive:

```
$PARA_LLM_ROOT/recovery/command-center-state-<session>     # persistent (survives reboot)
/tmp/tmux-command-center-state-<session>                   # fallback if ~/.para-llm-root missing
```
Row format: `pane_id|window_name|origin|project`.

**Restore** (`tmux-command-center.sh:76`) reverses it: stop the monitor, remove
hooks, then `break-pane -s <pane> -n <name> -d` for each row — recreating one
window per agent with its original name. Two hardening details that matter:

- If the state file is missing/empty it **reconstructs one** from the live panes
  (project = `basename $PWD`, branch from git) rather than refusing — losing the
  names is better than stranding the panes.
- The **last** pane in the CC gets `rename-window` instead of `break-pane`, because
  some tmux versions refuse `break-pane` on a window's last pane and fail
  silently — which used to leave the 7th+ agent with the wrong window name.

### 2.2 Focus-follows-size: `tmux-cc-focus.sh`

The problem it solves: with 6–7 tiled panes, each tile is short, and Claude
Code renders its **input box at the bottom of the pane** — so the box you are
typing into gets clipped off. The fix is a `main-vertical` layout where the
pane you focus is swapped into the big "main" slot.

```
   ┌──────────────────────────┬───────────────┐
   │                          │  agent-2      │
   │      FOCUSED AGENT       ├───────────────┤
   │   (main-pane-width 60%)  │  agent-3      │
   │                          ├───────────────┤
   │   full-height: input box │  agent-4      │
   │   is never clipped       ├───────────────┤
   │                          │  agent-5      │
   └──────────────────────────┴───────────────┘
```

Mechanism:

- `enable` sets `focus-events on` (mandatory — `pane-focus-in` never fires
  without it), applies the layout, and installs a **global** hook:
  `set-hook -g pane-focus-in "run-shell -b 'tmux-cc-focus.sh promote #{window_id} #{pane_id}'"`.
- `promote` self-guards to the `command-center` window, so other windows are
  untouched by the global hook.
- It respects a manual `Ctrl+b z` zoom (`window_zoomed_flag == 1` → return).
- Core move: `swap-pane -d -s <active> -t <main>`, then `select-pane <active>`,
  then re-apply `main-vertical`. `main` is defined as *the first pane in
  `list-panes` order* (index 0 = the main slot).
- **Re-entrancy guard:** `swap-pane` relocates the old main pane, and tmux emits
  a `pane-focus-in` for it. Without a guard that echo re-fires `promote` and the
  big pane oscillates. So a global option `@cc_promoting` is set to `1`, and a
  **background timer** (`PARA_CC_COOLDOWN`, default `0.4s`) clears it and then
  re-invokes `promote` — which converges once `active == main`, and also catches
  the case where you arrowed to yet another pane during the cooldown.

### 2.3 Per-pane state: two writers, one display option

Each pane's border label lives in a **per-pane tmux user option**,
`@pane_display`, which the window's `pane-border-format` renders. Using a tmux
option (rather than `#(cat file)`) avoids tmux's `#()` output caching, so
updates are instant.

Two independent processes write it:

**(a) `state-detector.sh`** — one per pane, started by `monitor-manager.sh
attach` when the CC opens. Polls at `0.3s`:

```
is_claude_session()  → grep last 30 lines for ❯ / ⏺ / ⎿ / ✽
  ├── yes → is_claude_working(): "esc to interrupt" in the last 3 lines?
  └── no  → has_child_processes(): pgrep -P <pane_pid>
is_tts_playing()     → /tmp/para-llm-tts/<safe>.pid or .prep.pid alive → suffix "+tts"
```
State → color/label → `tmux set-option -p -t <pane> pane-border-style fg=<color>`
and `@pane_display`. It also writes
`/tmp/claude-pane-mapping/by-cwd/<cwd_safe>` containing `PANE_ID/PROJECT/BRANCH`
— the reverse index that lets a Claude *hook* (which only knows a cwd) find the
pane.

**(b) `hooks/state-tracker.sh`** — invoked by Claude Code's own hooks
(`SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `Stop`,
`Notification[idle_prompt|permission_prompt]`), merged into the user's
`~/.claude/settings.json` at install time. It reads the hook JSON on stdin and
writes:

```
/tmp/claude-state/<session_id>.json
/tmp/claude-state/by-cwd/<cwd_safe>.json     # cwd_safe = cwd with '/' → '_', leading '_' stripped
```
with `{session_id, state, detail, cwd, tool, permission_mode, event, timestamp}`
where `state ∈ starting|working|ready|blocked|ended|unknown`. It then resolves
the pane via the mapping file (with a fallback that walks up to the env root for
multi-repo envs, and an auto-detect by matching `pane_current_path`) and writes
the border style + `@pane_display` **directly**, so the label updates on the
hook event rather than on the next 300ms poll.

Both writers deliberately re-assert the magenta `♪` TTS indicator so neither
clobbers the other between events.

| State | Color | Label |
|---|---|---|
| `ready` / `ended` | green | `Waiting for Input` |
| `working` / `starting` | yellow | `Working[: <tool>]` |
| `blocked` | cyan | `Needs Action: Permission` |
| any + TTS active | magenta | `♪ <label>` |

**Design note (ADR-007 / ADR-011):** hooks are the authoritative source for
`blocked`/`ended`, but the `Stop` hook is unreliable and there is no
`UserPromptSubmit` hook wired — so "is a turn running *right now*" is still read
from Claude's own on-screen footer string `esc to interrupt`, scoped to the last
few non-blank lines so scrollback can't match it. This hybrid is used identically
by the WM's state detector and by HFEF's heartbeat (§3.5).

### 2.4 Status line

`install.sh` appends three `#()` segments to `status-right`
(`status-interval 5`):

- `claude-state-monitor/tmux-status.sh` — aggregate across all
  `/tmp/claude-state/by-cwd/*.json`: `Claude: 2 ready, 1 working`.
- `stt/stt-status.sh` — red `REC` while `Ctrl+b a` dictation is recording.
- `tts/stream-status.sh` — the HFEF chip: `🔊SPEAK <label>` / `⏸PAUSED` /
  `🎤DICTATE` (§3.6).

### 2.5 Global tmux options set by `install.sh`

```tmux
set -g focus-events on            # required by tmux-cc-focus.sh
set -g mouse on
set -s extended-keys on           # Shift+Enter → newline in Claude Code (iTerm2 CSI u)
set -g pane-border-status top
set -g pane-border-style        '#{?#{@speak_on},fg=colour201 bold,default}'
set -g pane-active-border-style '#{?#{@speak_on},fg=colour201 bold,#{?pane_in_mode,...}}'
set -g pane-border-format       '... #{?#{@speak_on},#[bg=colour201...] 🔊 SPEAKING ...,}#{@pane_display} ...'
```

`@speak_on` is a **per-pane** option set by the HFEF toggle; the *format* is
global and evaluated per pane at draw time. That's the trick that lets a global
option produce a per-pane indicator.

### 2.6 Keybindings

| Key | Action |
|---|---|
| `Ctrl+b c` | create/resume a feature env (popup) |
| `Ctrl+b k` | cleanup an env (popup) |
| `Ctrl+b v` | command center toggle |
| `Ctrl+b b` | `synchronize-panes` (broadcast typing) |
| `Ctrl+b y` | switch this env between Claude Code and Codex |
| `Ctrl+b t` | remote save/restore menu |
| `Ctrl+b r` | manual session restore |
| `Ctrl+b a` | one-shot dictation (record → transcribe → inject) |
| `Ctrl+b p` | one-shot playback of latest pane output |
| **`Ctrl+b o`** | **HFEF speak mode toggle** (overrides tmux's default "cycle pane") |

---

## 3. The hands-free / eyes-free stack

### 3.1 Design premise

Eyes-free means: **you must be able to tell what is happening from sound
alone.** That produces three requirements the code takes seriously:

1. **Continuous narration** of what the agent writes, in order, comprehensible
   as speech (not markdown read aloud).
2. **An "it's working" signal** — silence must mean *your turn*, not *maybe it
   crashed*. Hence the heartbeat "sticks" loop.
3. **Voice-only actuation** — dictate, submit, transport controls, and
   *navigation between agents* without touching the keyboard.

Hands-free means the mic is always hot, which creates the dominant engineering
problem in this subsystem: **the speakers feed the mic**. Most of the
complexity in `wake-listener.sh` is self-echo defense (§3.4).

### 3.2 Entry point: `prototype/toggle-speak.sh` (`Ctrl+b o`)

```
bind-key o run-shell -b "bash $SCRIPT_DIR/prototype/toggle-speak.sh '#{pane_id}'"
```

Toggle semantics, and one hard invariant: **speak mode has a single global
owner.** Starting it on any pane first evicts whichever pane owned it.

```
PANE_ID=%46, SAFE=46

/tmp/para-speakloop/46.pid       narration loop pid (its own process group)
/tmp/para-speakloop/46.wake.pid  wake-listener pid
/tmp/para-speakloop/46.pause     touch = hold playback + interrupt current chunk
/tmp/para-speakloop/46.repeat    touch = run the catch-up recap
/tmp/para-speakloop/46.skip      touch = drop pending audio, jump to latest
/tmp/para-speakloop/46.replay    touch = re-speak the last block
/tmp/para-speakloop/46.log       stderr of speak_loop.py

/tmp/para-llm-tts/stream.pane            content = "46"  → THE OWNERSHIP LOCK
/tmp/para-llm-tts/46.stream/watcher.pid  liveness for the status chip
/tmp/para-llm-tts/46.stream/label        friendly name, resolved once at enable time
/tmp/para-llm-tts/46.stream/tts.speaking what the narration is saying RIGHT NOW
/tmp/para-llm-tts/46.stream/voice.active touched when the mic hears real words
/tmp/para-llm-tts/46.stream/paused       user-requested pause (distinct from .pause)
/tmp/para-llm-tts/46.stream/wake.state   "listening" | "dictating"
```

Startup order (matters):

1. If already running for this pane → `stop_pane` and exit (toggle off).
2. Read `stream.pane`; if a *different* pane owns it → `stop_pane` on that pane.
3. `mkdir` the spool, clear the channel files.
4. Launch `speak_loop.py` with `SPEAKLOOP_{PAUSE,REPEAT,SKIP,REPLAY}_FILE` in the
   environment; record its pid; also write it to `<spool>/watcher.pid` and write
   `<spool>/label` (these two exist purely so the pre-existing
   `stream-status.sh` chip lights up unmodified).
5. **Only if `whisper-stream` and `rec` are both on PATH:** write `stream.pane`
   and launch `wake-listener.sh` with the same channel env. *Without whisper,
   the status chip never appears* — `stream.pane` is written inside that branch.
6. Set the indicators: `@speakloop`, `@speak_on`, and
   `window-style bg=#3a2044` (the purple tint, `SPEAKLOOP_TINT`).
7. Unless `SPEAKLOOP_RECAP_ON_START=0`, touch `.repeat` → the first thing you
   hear is a catch-up briefing, not silence.

`stop_pane()` is written to tear down **any** pane's stack, because it is used
both for toggle-off and for eviction. It group-kills the loop (`kill -TERM
-$pgid`, then `-KILL`), TERMs the wake-listener (letting its own trap reap
whisper/`rec`), `pkill`s any stray `whisper-stream` scoped to that spool path,
removes the channel files and spool, and unsets `@speakloop`/`@speak_on`/
`window-style`. It deliberately does **not** `pkill -P` the wake-listener,
because during a `window` hand-off the new toggle process can be a *child* of
the old wake-listener and would kill itself.

### 3.3 Output path: `prototype/speak_loop.py`

The pipeline is seven daemon threads with queues between them. Nothing here
polls the screen.

```
agent_source.follow()            tail -n 0 -F <transcript>.jsonl
        │  TextChunk (one complete prose block the agent wrote)
        ▼
     chunk_q
        │  submitter(): ThreadPoolExecutor, K=SPEAKLOOP_REWRITE_WORKERS (2),
        │               capped at K+3 outstanding
        ▼
   rewrite pool ──► collector(): consumes futures in SUBMISSION order
        │
        ▼
     synth_q          ~1100-char chunks of whole sentences
        │  synthesizer(): ONE edge-tts call per chunk (single-threaded → FIFO)
        ▼
     audio_q  ───────────────┐
     prio_q   (recap/replay) ┤─► player(): afplay, strictly sequential
                             ┘
```

**Source adapters (`agent_source.py`).** This is what replaced screen-polling.

| Adapter | Transcript |
|---|---|
| `ClaudeCodeSource` | `~/.claude/projects/<cwd with [/.] → ->/<newest>.jsonl`; extracts `type=="assistant"` → `message.content[].type=="text"` |
| `CodexSource` | `~/.codex/sessions/**/rollout-*.jsonl`; extracts `type=="response_item"`, `payload.role=="assistant"`, content type `output_text`/`text` |
| `PollingSource` | stub — the fallback for a REPL with no transcript; deliberately unimplemented |

`for_pane()` maps `%N` → `pane_current_path` → whichever adapter finds a live
transcript. **Why this matters:** a transcript block is *already* a
complete-idea boundary (the agent writes prose, then calls a tool), so there is
no heuristic sentence/settling detection, no ANSI, no chrome, and nothing lost
to scroll-off. This is the single biggest simplification versus the older
`capture-pane` poll-and-diff design (ADR-010).

`recent_events()` additionally interleaves `user` records for the recap, and
filters out system-injected pseudo-user records (`<task-notification>`,
`<command-name>`, `<system-reminder>`, hook output, …) so the recap anchors on
things a human actually typed.

**Rewrite stage.** `block_narration()`:

- `split_block(text, target=2500)` on paragraph → sentence boundaries.
- Short *and* clean prose (`< TTS_STREAM_REWRITE_MIN_CHARS`, default 160, and no
  match for the `_CODEY` regex: backticks, URLs, paths, `.py/.js/.sh/...`,
  `=>`, `::`, `def`, `class`, `npm`, `git`, …) **skips the LLM entirely** — it's
  already speakable.
- Otherwise `claude -p --model haiku` with the `REWRITE_PROMPT` (45s timeout,
  one retry at 75s). Failure returns `""` and the block is **skipped**, never
  spoken raw — reading markdown aloud is worse than silence.
- `despeak()` strips residual list markers and `` `*#|>~ `` as a safety net.

Two latency rules are load-bearing and stated in the module docstring: rewrite
each block **once** (not per sub-piece), and synthesize whole ~1KB chunks (not
per sentence) so edge-tts's ~5s fixed overhead amortizes over ~20s of audio
instead of stuttering after each sentence. The `collector` exists solely to let
rewrites run in parallel while playback order stays strictly sequential.

**Synthesis.** `edge-tts --voice en-US-AndrewNeural --rate=+25%` (`SPEAKLOOP_RATE`),
falling back to macOS `say -r <wpm>` (the `+25%` is converted against a 175 wpm
base). Output is a temp file; the player unlinks it after playing.

**Player.** Per iteration: block while `.pause` exists; drain `audio_q` if
`.skip` exists; take from `prio_q` first (recap/replay preempt normal
narration), else `audio_q`. While `afplay` runs it polls every 80ms and
`terminate()`s on stop/pause/skip, and it `utime()`s `tts.speaking` every 400ms
so the mic guard can tell "audio is live right now" from mtime alone.

**Controller.** Watches `.repeat` and `.replay`:

- `.repeat` → `turn_context()` builds the last 2 request/response turns
  (`You:` / `Agent:`, 6000-char budget) → `recap()` via
  `SPEAKLOOP_RECAP_MODEL` (**sonnet**, deliberately stronger than the per-chunk
  haiku since it runs once) → enqueued on `prio_q`.
- `.replay` → re-speak `last_narr[0]` verbatim.
- Both set the `preparing` event so the heartbeat keeps ticking through the ~9s
  of LLM + first synth — otherwise "repeat" would be answered by dead silence.

### 3.4 Input path: `plugins/stt/wake-listener.sh`

One long-lived `whisper-stream` (model `ggml-tiny.en.bin`, auto-downloaded from
HuggingFace on first use, `--step 700 --length 6000`) writes a rolling
transcript to `<spool>/wake.log`; the listener `tail -F`s it and pattern-matches
each line.

**Command vocabulary** (all overridable via `$PARA_LLM_ROOT/config`):

| Word | Effect |
|---|---|
| `transcribe` (alias `subscribe`) | toggle dictation |
| `send` (aliases `sends`, `sent`) | press Enter in the bound pane |
| `pause` / `play` | hold / resume narration |
| `forward` | drop pending audio, jump to latest |
| `rewind` | replay the last block |
| `repeat` / `digest` | spoken catch-up recap |
| `window` | move speak mode to the next agent (§4.2) |
| `text box` | clear the input box (`C-c`, only if non-empty) |
| `diagnostic` | spoken health report, via local `say` (bypasses the pipeline) |

**Matching discipline.** `normalize()` strips whisper's noise annotations
(`[BLANK_AUDIO]`, `(clicking)`, `*music*`) *before* word counting — they used to
inflate utterance length past the strict limits and `[MUSIC PLAYING]` once
matched `play`. Words are matched by **8-character stem, word-prefix only** (so
`transcription`/`transcribed` work, but `send` never matches inside `ascend`).
`send` is the exception: whole-word only (`send`/`sends`/`sent`), because a bare
`send*` prefix false-fired on "just sending".

Utterance-length gates:

| Mode | Rule |
|---|---|
| `normal` | ≤2 words containing the stem; **exactly 1** while TTS audio is live |
| `end` (closing a dictation) | must *end* with the stem, ≤6 words — the stop word usually lands in the same whisper segment as the last dictated words |
| burst ("repeat-to-force") | ≥2 words, *all* of them the same command word → always fires, bypassing every guard |

**The self-echo problem, and its three defenses.** The narration plays through
the speakers; the mic hears it; a command word *inside the narration* would
actuate the workspace ("…then I'll send it to the window…").

1. `player_speaking()` — true if the player has a live `afplay` child **or**
   `tts.speaking` was touched ≤1s ago. While true, only a one-word utterance can
   trigger anything.
2. `tts_recently_said(stem)` — the loop publishes the last two spoken chunks to
   `<spool>/tts.speaking`; if the matched stem appears there within
   `STT_WAKE_ECHO_COOLDOWN` (4s), the match is **dropped as our own voice**.
3. `echo_stem` latch — a word that just fired lingers in whisper's ~6s sliding
   window and reappears in the next segments. After firing, that command is
   suppressed until a line arrives *without* it. This is **alias-aware**
   (`line_has_echo`): `transcribe`'s echo heard as "subscribe", and `send`'s
   echo heard as "sent", must also keep the latch armed — otherwise the trigger
   word's own echo clears the latch and immediately re-fires (transcribe would
   end its own dictation; send would submit twice).

The escape hatch: `is_burst` / `all_words_send`. Saying "send send send" is
unmistakably a human — narration never emits a segment of nothing but one
repeated command word — so a clean burst fires over live audio and past the echo
guard. This is the documented way to force a command while the agent is talking.

**Dictation flow** (`begin_dictation` → `end_dictation`):

1. `pause_playback()`: touch `.pause` (new loop) **and** `SIGSTOP` the old
   player/framing process trees, **and** `SIGKILL` the in-flight `afplay`
   children. SIGSTOP alone was not enough — a stopped loop still lets the
   in-flight `afplay` drain its CoreAudio buffer, so the current sentence would
   keep playing over the user. SIGKILL works on stopped processes; SIGTERM would
   stay pending until CONT.
2. Glass chime, `rec -b 16 -c 1 -r 16000 <spool>/dictation.wav`, red
   `🎤DICTATE` chip, `wake.state=dictating`.
3. On the stop word (or `STT_WAKE_MAX_DICTATION`, default 120s): kill the
   recorder (TERM, then KILL after ~3s — `sox` can wedge in CoreAudio teardown).
4. Guards before transcription: file `> 1000` bytes, and `sox stat` RMS
   amplitude `≥ 0.003` — whisper **hallucinates text on silence**, so a silent
   take is discarded rather than transcribed.
5. Full-quality transcription via `transcribe.sh` (whisper `base.en`, whole
   file — not the tiny streaming model).
6. A Python pass strips the command word from the transcript **edges** by stem,
   tolerating a courtesy "start"/"stop" said out of habit.
7. `\r`/`\n` collapsed to spaces (a literal newline in `send-keys -l` fragments
   the message inside Claude Code's input box).
8. **Re-check `mode_active`** — a long take can outlast the mode; stale
   dictation must not land in a pane that is no longer bound.
9. `tmux send-keys -t <pane> -l "$text"` — **no Enter**. Review before submit is
   the default; `send` is a separate, deliberate act.
10. Bottle chime on success, Basso buzz on failure. Resume playback *unless* the
    user had explicitly paused.

**`send` and the "did it actually submit?" problem.** This is worth
understanding because it is the one place HFEF reads the rendered screen:

```bash
capture_input_region()   # awk over `capture-pane -p`: the text between the
                         # BOTTOM-MOST pair of ────────── rules, with ❯ and
                         # NBSP padding stripped
wait_input_ready()       # poll that region until non-empty AND unchanged
                         # across two reads, max 2.5s
```

`do_send` waits for the injected text to settle before pressing Enter (Claude
Code ingests a big `send-keys` paste asynchronously; an early Enter submits
nothing and strands the message). After Enter it sleeps 300ms and re-reads the
region: **an empty box is the only honest evidence of submission.** Empty →
Hero chime + `📨 Sent`; still non-empty → Basso buzz + `⚠️ Send did not submit`.

`text box` (clear) uses the same reader for a different reason: a single `C-c`
clears a non-empty input box, but a `C-c` on an *already empty* box is the first
strike of the two-`C-c` sequence that **quits the Claude REPL**. So it captures
first and no-ops when empty.

**Feedback protocol** (the eyes-free vocabulary):

| Sound | Meaning |
|---|---|
| Pop | command accepted |
| Basso | command failed / refused |
| Glass | mic open, dictating |
| Bottle | transcript landed in the input box |
| Hero | **submitted** (deliberately louder — the one signal that can't be missed) |
| sticks scrape | the agent is working |
| silence | your turn |

### 3.5 The working heartbeat

`heartbeat()` in `speak_loop.py`. A dry "sticks rubbing" sample synthesized once
with `sox` into `/tmp/para-llm-tts/working-sticks.wav`, looped with
`TTS_STREAM_WORKING_GAP` (1.1s) between plays.

```python
wanted() = not paused
       and not speaking            # the voice is playing — that's not silence
       and not voice_active()      # mic heard real words <3s ago — don't mask the command
       and (is_working() or preparing)
```

`is_working()` (throttled to one check per 0.7s) is the ADR-011 hybrid:

```python
st = hook_state(cwd)                       # /tmp/claude-state/by-cwd/<cwd_safe>.json
False if st in ("blocked", "ended")         # authoritative silence — permission prompt, trust dialog
else footer_running(pane)                   # "esc to interrupt" in the last 4 non-blank lines
```

Why hybrid: the `Stop` hook is unreliable (a pane can sit at `working` forever →
the tone would never stop), and no `UserPromptSubmit` hook is wired (initial
thinking still reads the previous `Stop`'s `ready` → the tone would start late).
The footer corrects both directions. `blocked`/`ended` from the hook wins
outright, which is what cleanly silences the tone on a permission prompt without
matching any dialog chrome.

`voice.active` is touched by the wake-listener on any line whose `normalize()`
output is non-empty — which is why noise-annotation stripping happens *before*
that check: the sticks' own feedback rendered as `(clicking)` must not count as
"someone is talking".

### 3.6 Indicators (what HFEF shows for the sighted moments)

| Indicator | Mechanism | Scope |
|---|---|---|
| purple pane background | `window-style bg=#3a2044` set per-pane by the toggle | bound pane |
| magenta bold border | global `pane-border-style` format keyed on `@speak_on` | bound pane |
| `🔊 SPEAKING` chip in border | global `pane-border-format` keyed on `@speak_on` | bound pane — **but see §5.1** |
| `🔊SPEAK / ⏸PAUSED / 🎤DICTATE <label>` | `stream-status.sh` in `status-right` | session-wide |

`stream-status.sh` reads `stream.pane` → `<spool>/watcher.pid` (liveness) →
`<spool>/label`, then `wake.state` and `paused` to pick the variant. It
deliberately uses the label **captured at enable time** rather than re-deriving
it, because `tmux display-message -pt <dead-pane>` **exits 0 and silently falls
back to a different target** — re-deriving would name the wrong agent. It also
only treats `stream.pane` as stale after a 15s grace period, because a
border-option change during startup triggers a status redraw and would otherwise
clear the mode before it began.

---

## 4. How the two systems compose

### 4.1 The three shared keys

Everything the two subsystems share flows through three identifiers:

| Key | Form | Used by |
|---|---|---|
| **pane id** | `%46` → `SAFE=46` | tmux options (`@pane_display`, `@speak_on`, `window-style`), `/tmp/para-speakloop/46.*`, `/tmp/para-llm-tts/46.stream/`, `stream.pane`, `/tmp/claude-pane-display/46` |
| **cwd** | `#{pane_current_path}` | agent transcript lookup, hook state lookup, pane mapping, env label |
| **env label** | first path component after `envs/` | status chip, spoken hand-off announcement, pane border, window name |

⚠️ The cwd is encoded **two different ways** and they are not interchangeable:

```
Claude transcript dir:   re.sub(r"[/.]", "-", cwd)      →  -Users-me-code-envs-Proj-feat-Proj
Hook state file:         cwd.replace("/","_").lstrip("_")  →  Users_me_code_envs_Proj-feat_Proj
```

`speak_loop.py` uses the first (via `agent_source`) to find the transcript and
the second (via `hook_state`) to read working state — for the *same pane*. A
change to either encoding breaks one half of HFEF silently.

### 4.2 `window`: voice-driven window management

This is the most direct coupling. Saying **"window"** while speak mode is on
(`do_window`, `plugins/stt/wake-listener.sh:746`) does all of this:

```
1. list-panes of the BOUND PANE'S OWN WINDOW        ← not list-windows
2. target = the next pane, wrapping
3. ack (Pop), then `say "<env-label>"` immediately  ← instant "where am I" cue
4. tmux select-pane -t <target>                     ← NO select-window
5. relaunch: ( SPEAKLOOP_RECAP_ON_START=1 nohup toggle-speak.sh <target> & )
```

Two decisions here are the integration:

- **It cycles panes, not windows.** An earlier version called `select-window
  -t <sess>:+`, which *left the command-center grid* — the visual workspace the
  user (or an onlooker) is relying on. Staying inside the window means "next
  agent" means "next tile", and the grid survives.
- **`select-pane` is not cosmetic.** It fires `pane-focus-in`, which fires
  `tmux-cc-focus.sh promote`, which swaps that agent into the **big main pane**.
  So one spoken word simultaneously: moves narration to the next agent, speaks
  its name, queues a catch-up recap of *that* agent, moves the purple tint, and
  re-lays-out the screen so the newly-narrated agent is the large one. The audio
  workspace and the visual workspace stay in lockstep with a single actuation.

The relaunch is wrapped in `( ... & )` — a subshell that backgrounds the new
toggle and exits, reparenting it to init. Without that, the new toggle would be
a descendant of the old wake-listener, and the old stack's group-kill teardown
would kill the launcher mid-hand-off.

```
   "window"
      │
      ├─► say "<label>"                      (instant orientation)
      ├─► tmux select-pane ──► pane-focus-in ──► promote ──► swap-pane -d
      │                                                    └─► main-vertical
      └─► toggle-speak.sh <target>
              ├─► stop_pane(previous owner)   ← single-owner eviction
              ├─► speak_loop.py  (tails target's transcript)
              ├─► wake-listener  (whisper on target)
              ├─► @speak_on / window-style    (purple moves)
              └─► touch .repeat               ← recap of where you landed
```

### 4.3 The layout is a correctness dependency, not a nicety

The commit that introduced focus-promotion is titled *"focused agent gets the
big main pane (input never clipped)"*. In an eyes-free session that stops being
cosmetic:

- `capture_input_region()` locates the input box by finding the **bottom-most
  pair of `──────────` rules** in `capture-pane` output. If fewer than two rules
  are on screen, its `awk` exits and returns **empty**.
- In a short tile, Claude Code's input box is clipped — so the region reads
  empty even when text is present.

Consequences **[inferred, but follows directly from the code]**:

| Caller | Behavior when the region reads empty |
|---|---|
| `wait_input_ready()` | never sees non-empty → burns 2.5s → returns 1 → `send: input never settled; submitting best-effort` |
| `do_send()` post-check | empty box == "submitted" → **Hero chime fires even if nothing was submitted** (false positive) |
| `do_clear()` | thinks the box is already empty → no-ops instead of clearing |

So: *the window manager keeping the bound pane full-height is what keeps the
voice send-confirmation honest.* If you ever change the layout rules, or bind
speak mode to a pane that isn't promoted, this is the failure you will see —
and it is silent, because the failure mode is a **success** sound.

The invariant that holds today: the `window` command always `select-pane`s its
target, and `pane-focus-in` always promotes the selected pane inside the CC —
so the bound pane is the big pane by construction.

### 4.4 One state source, two output channels

```
                Claude Code hooks (PreToolUse/PostToolUse/Stop/Notification)
                                    │
                            state-tracker.sh
                                    │
                    /tmp/claude-state/by-cwd/<cwd_safe>.json
                          │                          │
              ┌───────────┘                          └───────────┐
              ▼                                                  ▼
   WINDOW MANAGER (eyes)                                 HFEF (ears)
   state-detector.sh + state-tracker.sh                  speak_loop.hook_state()
   → border color + @pane_display                        → heartbeat on/off
   → tmux-status.sh aggregate                            → blocked/ended = silence
```

Plus the same footer string `esc to interrupt` read by both
`state-detector.is_claude_working()` and `speak_loop.footer_running()`. This is
intentional: what you *see* on a border and what you *hear* as a heartbeat can
never disagree, because they are the same two signals combined the same way.

### 4.5 Single-owner across the grid

`stream.pane` is a global (not per-pane) lock file. Its content is the SAFE pane
id of the sole owner. Consequences:

- Exactly one tile in the command center is ever purple.
- `mode_active()` in the wake-listener is `cat stream.pane == SAFE` — every
  worker in the stack self-terminates when the file changes. The main loop is
  literally `while mode_active; do ... done`.
- Eviction is idempotent: `toggle-speak.sh stop_pane` works on any pane id, so
  starting anywhere cleans up everywhere.
- One audio device, one mic, one narrative thread — which is the whole point:
  N agents, but a human can only listen to one.

### 4.6 Creating an agent while HFEF is running

`Ctrl+b c` inside the command center joins the new pane into the grid and starts
a `state-detector.sh` for it. It does **not** touch speak mode — the new agent
becomes reachable by voice on the next `window` cycle (it's now a pane in the
same window). Note the seam in §5.2: that path re-applies the `tiled` layout.

---

## 5. Known seams, divergences, and gotchas

These are real, present in the code at `fb0a3b6`, and worth knowing before
changing anything.

**5.1 The `🔊 SPEAKING` chip is invisible inside the command center.**
`install.sh` sets `pane-border-format` **globally** with the `@speak_on` chip,
but `create_command_center` sets a **window-scoped** `pane-border-format` that
renders only `@pane_display`. Window options beat global ones, so inside the CC
the chip is gone. The purple tint (`window-style`, per-pane) and the magenta
border (`pane-border-style`, still global) do survive — so the bound agent is
still visually obvious, just not labelled. Fix, if wanted: fold the `@speak_on`
conditional into the CC's own `pane-border-format`.

**5.2 Two different layouts are applied to the same window.**
`tmux-command-center.sh` and `tmux-cc-focus.sh` use `main-vertical`;
`tmux-new-branch.sh:create_feature_window` and `tmux-cc-hooks.sh` still call
`select-layout tiled`. In practice the next `pane-focus-in` re-promotes to
`main-vertical`, so it self-heals — but there is a window of time where a newly
created agent flattens the grid.

**5.3 `tmux-cc-hooks.sh` is installed-but-disabled.**
`setup_hooks()` is commented out in `create_command_center` ("Hooks disabled for
stability"), yet `cleanup_hooks()` still unsets those hooks. So
`after-new-window` / `pane-exited` / `window-unlinked` handling is dormant; new
windows are joined by `tmux-new-branch.sh` directly instead.

**5.4 `speak_loop.py` calls `claude -p`, which ADR-009 retired.**
ADR-009 removed headless `claude -p` as the TTS summarizer backend because
headless mode meters against a separate paid credit pool, and made `codex` the
only summarizer. The newer speak loop reintroduces `claude -p` for both the
per-chunk rewrite (haiku) and the recap (sonnet). That is a per-block metered
call for every prose block the agent writes. Whether that's intended is a
product decision, but the two documents currently disagree and the ADR has not
been amended.

**5.5 The docs describe the previous speak mode.**
`.llm-context/topics/product-features.md §11` documents `Ctrl+b o` as the
poll-and-diff stack (`toggle-stream.sh` → `stream-watcher.sh` →
`stream-step.py` → `stream-synth.sh` → `stream-player.sh`). `install.sh` now
binds `Ctrl+b o` to `prototype/toggle-speak.sh`, and no binding points at the
old stack at all. Those scripts still exist and `wake-listener.sh` still carries
its old-stack code paths (guarded by `if [[ -n "${SPEAKLOOP_PAUSE_FILE:-}" ]]`,
which is set only by the new toggle) — so the listener works with either, but
only the new one is reachable from a keybinding.

**5.6 `whisper-stream` missing ⇒ no status chip.**
`echo "$SAFE" > "$STREAM_PANE"` lives inside the `if whisper-stream && rec`
branch. Without them you get narration but `stream-status.sh` shows nothing, and
`mode_active()` would be false for any listener that did start.

**5.7 The production HFEF stack lives in `prototype/`.**
`toggle-speak.sh`, `speak_loop.py`, and `agent_source.py` are the shipped
implementation despite the directory name.

**5.8 Broadcast mode + voice injection.**
`Ctrl+b b` toggles `synchronize-panes`, documented by tmux as "Duplicate input
to all other panes in the same window". tmux routes `send-keys` through the same
input path, so dictation injected by the wake-listener would land in **every**
agent in the grid while broadcast is on. **[inferred — the man page wording
supports it and tmux's `window_pane_key` duplicates keys, but this was not
verified empirically here.]** Nothing in the code guards against this; don't
leave broadcast on during an eyes-free session.

**5.9 `tmux display-message -pt <dead-pane>` exits 0.**
It silently falls back to another target instead of failing. Pane liveness must
be checked with `tmux list-panes -a` + exact match. This bit both subsystems
historically; `stream-status.sh` and `state-tracker.sh` both encode the
workaround.

---

## 6. Configuration reference

All read from `$PARA_LLM_ROOT/config` (sourced via `~/.para-llm-root`) or the
environment.

**Window manager**

| Var | Default | Effect |
|---|---|---|
| `PARA_CC_MAIN_WIDTH` | `60%` | width of the focused/main pane |
| `PARA_CC_COOLDOWN` | `0.4` | seconds the promote re-entrancy guard holds |
| `STATUS_LINE_ENABLED` | `1` | aggregate Claude state in `status-right` |
| `STATUS_LINE_PREFIX` | `Claude` | label for that segment |
| `STATUS_LINE_EMOJI` | `0` | emoji instead of words |

**HFEF — narration**

| Var | Default | Effect |
|---|---|---|
| `SPEAKLOOP_TINT` | `#3a2044` | bound-pane background; empty disables |
| `SPEAKLOOP_ENGINE` | `edge` | `edge` (edge-tts) or `say` |
| `SPEAKLOOP_RATE` | `+25%` | speaking rate |
| `SPEAKLOOP_RECAP_ON_START` | `1` | catch-up briefing on enable / hand-off |
| `SPEAKLOOP_RECAP_MODEL` | `sonnet` | model for the recap |
| `TTS_STREAM_REWRITE_MODEL` | `haiku` | model for per-block rewrite |
| `SPEAKLOOP_REWRITE_WORKERS` | `2` | parallel rewrites in flight |
| `SPEAKLOOP_SYNTH_CHARS` | `1100` | chars per edge-tts call |
| `TTS_STREAM_REWRITE_MIN_CHARS` | `160` | below this (and non-codey) → skip the LLM |
| `TTS_STREAM_WORKING_ENABLED` | `1` | heartbeat on/off |
| `TTS_STREAM_WORKING_VOLUME` | `1` | heartbeat volume |
| `TTS_STREAM_WORKING_GAP` | `1.1` | seconds between sticks |
| `TTS_STREAM_WORKING_SOUND` | — | override the sticks file |

**HFEF — voice commands**

| Var | Default | Effect |
|---|---|---|
| `STT_WAKE_TRANSCRIBE_WORD` | `transcribe` | dictation toggle |
| `STT_WAKE_SEND_WORD` | `send` | submit |
| `STT_WAKE_REPEAT_WORD` / `_DIGEST_WORD` | `repeat` / `digest` | recap |
| `STT_WAKE_WINDOW_WORD` | `window` | next agent |
| `STT_WAKE_PAUSE_WORD` / `_PLAY_WORD` | `pause` / `play` | transport |
| `STT_WAKE_FORWARD_WORD` / `_REWIND_WORD` | `forward` / `rewind` | seek |
| `STT_WAKE_CLEAR_WORD` | `text box` | clear input |
| `STT_WAKE_DIAGNOSTIC_WORD` | `diagnostic` | health report |
| `STT_WAKE_MODEL` | `ggml-tiny.en.bin` | streaming spotter model |
| `STT_WAKE_STEP_MS` | `700` | whisper step (lower = faster detection) |
| `STT_WAKE_MAX_DICTATION` | `120` | seconds before a take auto-closes |
| `STT_WAKE_ECHO_COOLDOWN` | `4` | seconds a spoken word stays "in the air" |
| `STT_WAKE_{ACK,FAIL,SEND,START,STOP}_SOUND` | Pop/Basso/Hero/Glass/Bottle | feedback tones |

---

## 7. Walkthroughs

### 7.1 Cold start into an eyes-free session

```
Ctrl+b v                 → CC created: all agents joined, main-vertical,
                           focus hook installed, state monitors attached
(arrow to agent 3)       → pane-focus-in → promote → agent 3 is the big pane
Ctrl+b o                 → evict previous owner (none) → speak_loop + wake-listener
                           on agent 3 → purple tint, magenta border, 🔊SPEAK chip
                           → .repeat touched
[~9s of sticks]          → preparing=True keeps the heartbeat alive
"Here's where things stand: you asked for … the agent found … it's blocked on …"
[live narration begins as new transcript blocks land]
```

### 7.2 Dictate → review → submit

```
you: "transcribe"        → Pop? no — Glass. playback frozen, in-flight afplay killed,
                           🎤DICTATE chip, rec running
you: "add a retry around the network call"
you: "transcribe"        → Bottle. rec killed, RMS checked, base.en transcribes,
                           edge command words stripped, newlines collapsed,
                           mode re-checked, send-keys -l (no Enter)
[text now visible in the input box; playback resumes]
you: "send"              → wait_input_ready (region stable) → Enter → 300ms →
                           region empty? → Hero + "📨 Sent"
                                         else → Basso + "⚠️ Send did not submit"
[sticks resume as the hook state flips to working]
```

Shortcut: saying `"…add a retry around the network call. Send."` ends the take
**and** submits in one breath (`ends_with_send` accepts the command punctuated as
its own sentence at the tail, ≤12 words).

### 7.3 Moving to the next agent

```
you: "window"            → Pop
                         → say "MyProject-other-feature"          (immediate)
                         → select-pane %51
                              └─► pane-focus-in → promote → %51 becomes the big pane
                         → toggle-speak.sh %51 (detached)
                              ├─► stop_pane %46: group-kill loop, TERM listener,
                              │                  pkill whisper, unset @speak_on,
                              │                  clear tint, rm spool
                              ├─► claim stream.pane = 51
                              ├─► start loop + listener on %51
                              └─► touch .repeat
[~9s sticks] → "You asked it to migrate the schema; it's written the migration
                and is waiting for your approval on the destructive step."
```

---

## 8. Debugging map

| Symptom | Look at |
|---|---|
| No narration at all | `/tmp/para-speakloop/<safe>.log` — first line is `[source: claude] <path>`; `None` means no transcript resolved (wrong cwd encoding, or Codex/Claude mismatch) |
| Narration but no voice commands | `whisper-stream` / `rec` on PATH? `/tmp/para-llm-tts/<safe>.stream/wake.log` (raw whisper), `error.log`, and `/tmp/para-llm-tts/stream.log` (lifecycle) |
| Commands fire from the agent's own speech | check `<spool>/tts.speaking` freshness and `STT_WAKE_ECHO_COOLDOWN`; the guard needs the player's `utime()` refresh to be running |
| `send` chimes but nothing submits | `capture_input_region` is reading a clipped box — is the bound pane the promoted main pane? (§4.3) |
| Sticks never stop | `cat /tmp/claude-state/by-cwd/<cwd_safe>.json` and `tmux capture-pane -p -t <pane> \| tail -4 \| grep 'esc to interrupt'` (ADR-011) |
| Status chip missing | `stream.pane` content vs `<spool>/watcher.pid` liveness; chip only appears when whisper is installed (§5.6) |
| Big pane oscillates | `tmux show-option -gv @cc_promoting` stuck at `1`; `tmux-cc-focus.sh enable` clears it |
| Panes lost after closing CC | the state file under `$PARA_LLM_ROOT/recovery/` — restore rebuilds it from live panes if absent |
| Say `diagnostic` | spoken health report via local `say`, deliberately bypassing the pipeline so it works when the pipeline is what's broken |

---

## 9. File index

| File | Role |
|---|---|
| `tmux-command-center.sh` | CC create/goto/restore, layout, state file, monitor lifecycle |
| `tmux-cc-focus.sh` | `pane-focus-in` hook; promotes focused pane to main |
| `tmux-cc-hooks.sh` | dynamic window/pane handlers (currently dormant, §5.3) |
| `tmux-new-branch.sh` | env creation; joins new panes into the CC |
| `plugins/claude-state-monitor/state-detector.sh` | per-pane 0.3s poller → `@pane_display` + border |
| `plugins/claude-state-monitor/monitor-manager.sh` | attach/detach detectors for the CC |
| `plugins/claude-state-monitor/hooks/state-tracker.sh` | Claude hook handler → `/tmp/claude-state/**` + direct border update |
| `plugins/claude-state-monitor/tmux-status.sh` | aggregate status-right segment |
| `prototype/toggle-speak.sh` | `Ctrl+b o`; single-owner lifecycle for the HFEF stack |
| `prototype/speak_loop.py` | tail → rewrite → synth → play; recap/replay; heartbeat |
| `prototype/agent_source.py` | framework-agnostic transcript adapters |
| `plugins/stt/wake-listener.sh` | always-on whisper command listener + dictation |
| `plugins/stt/transcribe.sh` | full-quality `base.en` transcription |
| `plugins/tts/stream-status.sh` | `🔊SPEAK/⏸PAUSED/🎤DICTATE` status chip |
| `plugins/tts/*` (rest) | previous poll-and-diff speak mode; no longer bound (§5.5) |
| `install.sh` | writes all tmux bindings/options; merges Claude hooks config |

---

## 10. If you are changing this code

- **Adding a voice command:** add the stem, add an `elif` branch in the
  listening state machine, and decide its echo policy (`matches_word` normal vs
  a custom matcher). Every new command needs an `echo_stem` latch entry or it
  will re-fire on its own whisper echo.
- **Changing the layout:** anything that can leave the bound pane short breaks
  `capture_input_region` (§4.3). If a short bound pane becomes possible, make
  `do_send` fail closed — treat "region unreadable" as *not submitted* rather
  than as an empty box.
- **Adding an agent framework:** implement `locate()` + `extract()` on
  `AgentSource`, add it to `for_pane()`. Nothing else in HFEF needs to know.
- **Changing cwd encoding anywhere:** you must change it in both places (§4.1),
  or narration and heartbeat will disagree about which agent they're on.
- **Touching teardown:** preserve the detached-relaunch trick in `do_window`
  and the "no `pkill -P` on the wake-listener" rule in `stop_pane`, or the
  hand-off kills its own successor.
