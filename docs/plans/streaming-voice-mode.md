# Streaming Voice Mode ("Speak Mode") — Implementation Plan

Status: **proposed** (this PR contains the plan only; implementation follows in
subsequent PRs on this branch or stacked branches).

## What we're building

Two things, delivered in phases:

1. **Phase 1 — Speak mode (`Ctrl+b o`)**: a per-pane *mode* (not a one-shot
   action like `Ctrl+b p`) that speaks the agent's output as it streams into
   the pane, with minimal delay. Toggle on with `Ctrl+b o`, visible in the
   tmux status bar, toggle off with `Ctrl+b o` again. Bound to exactly one
   pane at a time.
2. **Phase 2 — Hands-free dictation via wake word ("abracadabra")**: while
   speak mode is on, a background listener waits for the magic word. Saying
   it starts dictation into the bound pane; saying it again ends dictation
   and injects the transcript — no `Ctrl+b a` needed. Feasibility analysis
   below; conclusion: **feasible with zero new dependencies** using
   `whisper-stream` (already installed by the `whisper-cpp` brew formula).

## UX spec

### Speak mode toggle

- `Ctrl+b o` in a pane → speak mode ON, bound to that pane.
  - If speak mode is already bound to a *different* pane, the mode moves to
    the current pane (old watcher stops, message shown), matching the
    existing "steal the playback slot" behavior of `Ctrl+b p`.
- `Ctrl+b o` in the bound pane → speak mode OFF (watcher, synthesizer, and
  player all stop; queued audio is discarded).
- **Note:** `Ctrl+b o` overrides tmux's default binding (cycle to next
  pane). Acceptable per requirements; the install script will call this out.

### Status bar

- New segment in `status-right`: `🔊 SPEAK %12` (green, bold) when speak mode
  is active, showing the bound pane id; nothing when off. Follows the
  pattern of `plugins/stt/stt-status.sh` (`REC` indicator).
- While dictating via wake word (Phase 2): the segment switches to
  `🎤 DICTATE %12` (red) so mode state is always visible at a glance.

### Interplay with existing voice features

- **`Ctrl+b p` one-shot playback**: speak mode claims the existing
  `/tmp/para-llm-tts/active.pane` slot. Enabling speak mode stops any
  in-flight one-shot playback; pressing `Ctrl+b p` while speak mode owns the
  slot shows "speak mode active on %N — Ctrl+b o to stop" and does nothing.
- **`Ctrl+b a` manual STT**: unchanged, still works. During Phase 2
  dictation the speak-mode audio player is paused so TTS output doesn't leak
  into the dictation or read back while you're talking.

## Phase 1 architecture — streaming TTS

Three cooperating background processes per bound pane, connected by a spool
directory (`/tmp/para-llm-tts/<pane>.stream/`), all managed by a new
`plugins/tts/toggle-stream.sh`:

```
┌──────────┐  sentence chunks   ┌─────────────┐  mp3 per chunk   ┌────────┐
│ watcher  │ ─── NNN.txt ─────▶ │ synthesizer │ ─── NNN.mp3 ───▶ │ player │
│ (poll +  │                    │ (edge-tts,  │                  │(afplay,│
│  diff)   │                    │  say fall-  │                  │ strict │
└──────────┘                    │  back)      │                  │ order) │
                                └─────────────┘                  └────────┘
```

### Watcher: turning a redrawing TUI into an append-only text stream

The core problem: Claude Code / Codex TUIs constantly redraw the spinner,
input box, and the currently-streaming paragraph, so raw `pipe-pane` output
is unusable (infinite ANSI redraw noise). Instead the watcher polls
`tmux capture-pane -p -S -` (~every 700 ms, configurable), cleans it with the
same ANSI-strip + chrome filters as `extract-latest.sh`, and computes what's
*new and settled*:

- Maintain the previously-spoken filtered transcript (line count + tail
  hash) in the spool dir.
- A line is **settled** (safe to speak) when it is identical across two
  consecutive polls — this excludes the mutating tail (spinner, input box,
  paragraph still being streamed) without needing to understand the TUI.
- New settled lines are appended to a pending-text buffer; the buffer is cut
  into chunks at sentence boundaries (reusing the splitting logic already in
  `toggle-tts.sh:split_speech_for_synthesis`), and each chunk is written as
  the next `NNN.txt` spool file.
- If the pane is cleared or scrollback shrinks (transcript no longer a
  superset of what we tracked), the watcher resets its anchor rather than
  re-speaking history.

**What gets spoken:** assistant prose only. The watcher reuses
`extract-latest.sh`'s filters (box-drawing, "esc to interrupt", trust
prompts) and adds streaming-specific ones: tool-call/result blocks, diffs and
fenced code blocks are skipped (optionally replaced by a short cue like
"code block"), spinner/status lines dropped. Filters live in a shared
`plugins/tts/filter-pane-text.sh` so `extract-latest.sh` and the watcher
can't drift apart.

**No summarization.** Unlike `Ctrl+b p`, speak mode reads the actual text as
it arrives — summarizing would defeat streaming. `TTS_SUMMARIZE` does not
apply here.

### Synthesizer

- Consumes `NNN.txt` spool files in order; produces `NNN.mp3` via `edge-tts`
  with the existing voice/rate/volume/pitch settings, per-chunk timeout
  (`TTS_SYNTH_TIMEOUT`), one retry, then the local `say` fallback — same
  hardening as the current `synthesize_chunk`/`synthesize_local_chunk`,
  refactored into a shared `plugins/tts/synthesize.sh` used by both modes.
- Runs ahead of the player: while chunk N plays, N+1..N+k synthesize, so
  network latency is hidden after the first sentence.

### Player

- Plays `NNN.mp3` strictly in sequence with `afplay`; waits (with the
  familiar Tink ambient cue suppressed — this is a mode, constant beeping
  would be noise) when the next chunk isn't ready yet.
- Exposes its PID so Phase 2 can pause/resume it (SIGSTOP/SIGCONT) during
  dictation.

### Latency budget

Poll interval (0.7 s) + settle confirmation (1 poll) + sentence completion +
edge-tts synth (~1–2 s/sentence, pipelined) ⇒ speech trails the text by
roughly **2–4 s** steady-state, first utterance ~3–5 s after the first full
sentence settles. `TTS_STREAM_POLL_INTERVAL` and the local-`say` engine
option (`TTS_STREAM_ENGINE=say`) give a lower-latency, lower-quality knob.

### State, lifecycle, and hardening

- Mode state file `/tmp/para-llm-tts/stream.pane` (bound `SAFE_PANE_ID`) +
  per-process PID files in the spool dir, following the existing PID-file +
  `kill_tree` + toggle-lock conventions from `toggle-tts.sh` (reused, not
  reimplemented, where practical).
- Watcher exits automatically (and clears the mode) if the bound pane dies
  (`tmux display-message -t` fails), so a closed window can't leave orphan
  loops — same class of bug already fixed for STT (see `bugs-fixed`).
- All errors append to `<pane>.stream/error.log`; a synth failure skips the
  chunk after fallback rather than wedging the queue.

### Config knobs (all optional, `$PARA_LLM_ROOT/config`)

| Variable | Default | Meaning |
|---|---|---|
| `TTS_STREAM_POLL_INTERVAL` | `0.7` | capture-pane poll cadence (s) |
| `TTS_STREAM_MIN_CHARS` | `60` | min pending chars before forcing a chunk w/o sentence end |
| `TTS_STREAM_ENGINE` | `edge-tts` | `edge-tts` or `say` (local, lower latency) |
| `TTS_STREAM_SPEAK_CODE` | `0` | `1` = read code blocks; default replaces with a cue |

## Phase 2 — wake-word dictation: feasibility & design

### Feasibility: YES, with zero new dependencies

Options evaluated:

| Approach | Verdict |
|---|---|
| **`whisper-stream`** (whisper.cpp streaming CLI) | **Recommended.** Already installed (`brew install whisper-cpp` ships it — verified present on this machine). Continuous mic transcription in ~3 s steps with VAD; write segments to a file, fuzzy-match the wake word. Uses the models we already download. |
| Picovoice Porcupine | Purpose-built hotword engine, lowest CPU, but a custom keyword ("abracadabra") requires Picovoice Console training + access key; new dependency + account. Rejected for v1. |
| openWakeWord | Open source, but no pre-trained "abracadabra" model; custom training pipeline required. Rejected for v1. |
| macOS `hear` / Voice Control | Not installed / not scriptable enough. Rejected. |

"Abracadabra" is a good wake word for transcription-based spotting: 5
syllables, phonetically distinctive, essentially never appears in normal
dictation. Matching is normalized (lowercase, strip punctuation/spaces, allow
"abra cadabra") against each new `whisper-stream` segment.

### Design

A `plugins/stt/wake-listener.sh` daemon, started/stopped by
`toggle-stream.sh` when speak mode toggles (gated by `STT_WAKE_ENABLED=1`,
default off initially):

```
LISTENING ──"abracadabra"──▶ DICTATING ──"abracadabra"──▶ inject & back to LISTENING
```

- **LISTENING**: `whisper-stream` runs continuously with the **tiny.en**
  model (keyword spotting doesn't need base.en accuracy; lower CPU), `-f`
  writing segments to `/tmp/para-llm-stt/wake.log`; the listener tails it.
- **Wake word heard** → chime, pause the speak-mode player (SIGSTOP), status
  segment flips to `🎤 DICTATE`, start dictation.
- **Dictation capture — two options, decided by a validation spike:**
  - **(a) Reuse the proven path** (preferred for quality): start the
    existing sox `rec` → `whisper-cli` full-file flow from `toggle-stt.sh`,
    while the wake listener keeps running only to spot the closing
    "abracadabra". Full-file base.en transcription gives the best accuracy
    and reuses hallucination/RMS guards. Requires macOS to allow two
    simultaneous mic captures (CoreAudio generally does — **spike task 1**
    verifies sox + whisper-stream coexist). The closing wake word lands in
    the recorded WAV, so the transcript gets trailing wake-word stripping.
  - **(b) Single capture**: buffer whisper-stream's own segments between the
    two wake words and inject that text. Simpler resource story, no mic
    contention, but streaming-quality transcription (weaker punctuation).
    Fallback if (a)'s dual capture fails.
- **Closing wake word** → stop dictation, strip leading/trailing wake words
  from the transcript, inject into the bound pane via the existing
  `tmux send-keys -l` path, resume the player (SIGCONT), chime.
- **Safety valves**: dictation auto-ends after `STT_WAKE_MAX_DICTATION`
  (default 120 s); listener dies with speak mode; `kill_recorder`-style
  TERM→KILL escalation reused for whisper-stream.

### Risks / mitigations

- **False positives from TTS audio** (the speaker saying something the mic
  hears): user wears headphones (stated assumption), and the wake word is
  rare; additionally the player is paused during dictation so it can't
  pollute the transcript. If false wakes show up on speakers, add
  "pause listener while player is actively playing" as a config option.
- **CPU**: tiny.en streaming on Apple Silicon (Metal) is light; measured in
  the spike. If it's noticeable, raise `--step` to 4000–5000 ms (costs wake
  latency, ~irrelevant for a wake word).
- **Mic contention** (option a): spike verifies; option (b) is the fallback.
- **Wake latency**: with 3 s steps, expect the word to register in ~2–4 s;
  chime feedback makes this predictable in practice.

## File-level change list

Phase 1:

- `plugins/tts/toggle-stream.sh` — **new**: mode toggle, lifecycle, retarget.
- `plugins/tts/stream-watcher.sh` — **new**: poll/diff/settle/chunk loop.
- `plugins/tts/synthesize.sh` — **new (extracted)**: shared chunk synthesis
  (edge-tts + retry + say fallback), used by `toggle-tts.sh` too.
- `plugins/tts/filter-pane-text.sh` — **new (extracted)**: shared chrome
  filters, used by `extract-latest.sh` too.
- `plugins/tts/stream-status.sh` — **new**: status-bar segment.
- `plugins/tts/toggle-tts.sh` — refuse to start one-shot playback while
  speak mode owns the slot; use extracted helpers.
- `install.sh` — `bind-key o run-shell -b .../toggle-stream.sh`; append
  `stream-status.sh` (and the existing but currently-unwired
  `stt-status.sh`) to `status-right`; keybinding summary text.

Phase 2:

- `plugins/stt/wake-listener.sh` — **new**: whisper-stream supervisor +
  state machine.
- `plugins/stt/toggle-stt.sh` — factor `start_recording` /
  `stop_and_transcribe` for reuse by the listener; wake-word stripping in
  the transcript path.
- `plugins/tts/toggle-stream.sh` / `stream-status.sh` — start/stop listener
  with the mode; DICTATE indicator.
- `para-llm-config.sh` / config docs — `STT_WAKE_ENABLED`,
  `STT_WAKE_WORD` (default `abracadabra`), `STT_WAKE_MODEL` (tiny.en),
  `STT_WAKE_MAX_DICTATION`.

Docs (per project conventions, done with each implementation PR):

- `.llm-context/topics/product-features.md` — speak mode + wake dictation
  usage; key bindings summary.
- `.llm-context/topics/architectural-decisions.md` — ADR-010: poll-and-diff
  capture-pane streaming (why not pipe-pane / hooks); ADR-011:
  whisper-stream transcription-matching for wake word (why not a dedicated
  hotword engine).
- `.llm-context/topics/tech-stack.md` — note `whisper-stream` + tiny.en use.
- `.llm-context/topics/debugging.md` — spool dir layout, error/progress logs.

## Validation / test plan

1. **Spike 1 (before Phase 2 build)**: run `rec` and `whisper-stream`
   concurrently; confirm both capture. Measure whisper-stream tiny.en CPU.
2. Phase 1 manual matrix: enable on Claude pane mid-response; enable before
   sending a prompt; toggle off mid-speech (audio stops < 1 s); retarget to
   second pane; kill bound pane (mode clears itself); `Ctrl+b p` while
   active (refused with message); network down (say fallback engages);
   pane `clear` (no re-speak).
3. Phase 2 manual matrix: wake → dictate → wake → text lands in bound pane
   with wake words stripped; dictation timeout; TTS paused during dictation
   and resumed after; false-positive soak (30 min of normal speech near the
   mic, expect zero wakes).

## Open questions (defaults chosen, flag if wrong)

1. `Ctrl+b o` replaces tmux's default "next pane" binding — assumed OK.
2. Retargeting: pressing `Ctrl+b o` on a *new* pane moves the mode there in
   one press (vs. requiring off-then-on). Assumed the one-press move.
3. Wake word dictation injects text but does **not** press Enter — you
   review and submit. (An `STT_WAKE_AUTO_SUBMIT` option can add
   auto-Enter later.)
