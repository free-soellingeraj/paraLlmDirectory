# Hands-Free / Eyes-Free (HFEF) + Window Manager

Full reference: **`docs/hands-free-eyes-free-and-window-manager.md`** — architecture,
integration seams, walkthroughs, debugging map, config reference.

## The two subsystems

**Window manager** — `Ctrl+b v` (`tmux-command-center.sh`) joins every agent pane
into one `command-center` window; `tmux-cc-focus.sh` installs a `pane-focus-in`
hook that swaps the focused agent into the big `main-vertical` pane; per-pane
state (working / waiting / blocked) is written to the `@pane_display` tmux option
by both `state-detector.sh` (0.3s poll) and `hooks/state-tracker.sh` (Claude Code
hooks → `/tmp/claude-state/by-cwd/<cwd_safe>.json`).

**HFEF** — `Ctrl+b o` (`prototype/toggle-speak.sh`) binds exactly one pane:
- `prototype/speak_loop.py` tails the agent's own JSONL transcript
  (`prototype/agent_source.py`), rewrites each complete prose block into speech
  (`claude -p`, haiku), synthesizes ~1KB chunks (edge-tts), plays them in order,
  and loops a "sticks" heartbeat while the agent is working.
- `plugins/stt/wake-listener.sh` runs `whisper-stream` continuously for
  single-word commands: transcribe / send / pause / play / forward / rewind /
  repeat / window / text box / diagnostic.

## The three couplings that matter

1. **Pane id is the shared primary key** — `%N` → `SAFE=N` names every tmux
   option, spool dir (`/tmp/para-llm-tts/N.stream/`), and channel file
   (`/tmp/para-speakloop/N.*`). `/tmp/para-llm-tts/stream.pane` is the
   single-owner lock: exactly one pane is ever narrated/purple.
2. **`window` is voice-driven window management** — it cycles panes *within the
   command-center window* (never `select-window`), `select-pane`s the target
   (which fires `pane-focus-in` → promote → target becomes the big pane), speaks
   the env label, and relaunches the HFEF stack there with a recap.
3. **The layout is a correctness dependency** — `capture_input_region()` in the
   wake-listener parses the *rendered* input box (text between the bottom-most
   pair of `──────────` rules). A clipped pane returns empty, which makes
   `do_send`'s "did it submit?" check report success falsely. Keeping the bound
   pane full-height is what keeps voice submit honest.

## Known seams (as of `fb0a3b6`)

- The `🔊 SPEAKING` border chip is overridden inside the command center (its
  window-scoped `pane-border-format` drops the `@speak_on` conditional).
- `tmux-new-branch.sh` / `tmux-cc-hooks.sh` still apply `tiled`, not
  `main-vertical`; the next focus event self-heals it.
- `speak_loop.py` uses `claude -p`, which ADR-009 retired as a TTS backend on
  metered-billing grounds. The ADR has not been amended.
- `product-features.md §11` still documents the previous poll-and-diff speak
  mode (`toggle-stream.sh` + `stream-*.sh`); nothing binds it any more.
- The shipped HFEF implementation lives in `prototype/`.

**File**: `docs/hands-free-eyes-free-and-window-manager.md`
