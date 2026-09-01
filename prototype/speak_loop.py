#!/usr/bin/env python3
"""
speak_loop.py — the end-to-end tail -> rewrite -> speak loop (prototype).

Pipeline, all stages concurrent with queues between them:

    AgentSource.follow()          # tail the transcript (no screen polling)
        -> chunk_q                # one complete-idea text block per item
        -> rewrite pool (ordered) # K parallel `claude -p` rewrites, results
                                  #   consumed strictly in submission order
        -> synth_q                # narration split into ~1KB speakable chunks
        -> synth worker           # ONE edge-tts call per chunk (not per sentence)
        -> audio_q                # audio files, in order
        -> play worker            # afplay, strictly sequenced

`claude -p` costs ~20s/call and edge-tts ~5s of fixed overhead/call, so the two
rules that keep playback smooth are: (1) rewrite each block ONCE, not once per
sub-piece, and skip the LLM entirely for short clean prose; (2) synthesize whole
~1KB chunks, not per sentence, so the 5s overhead amortizes over ~20s of audio
instead of stuttering after every sentence. The parallel rewrite pool lets the
~20s latency hide behind playback and a buffer build during the agent's tool
pauses. Each chunk is already a complete idea (a prose block the agent wrote
before its next tool call), so there is no heuristic boundary detection.

Usage:
    python3 speak_loop.py <pane|cwd> [--backlog N] [--no-follow]
                          [--model haiku|sonnet] [--engine edge|say] [--dry]

    # hear the last 2 things the agent said, then follow live:
    python3 speak_loop.py %46 --backlog 2
    # prove the pipeline without audio (prints narration):
    python3 speak_loop.py %46 --backlog 3 --no-follow --dry
"""
from __future__ import annotations

import argparse
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agent_source import for_pane  # noqa: E402


def _ts_epoch(ts: str) -> float | None:
    """Parse a transcript ISO timestamp ('2026-08-13T16:47:26.417Z') to epoch
    seconds. None if absent/unparseable — callers fail open (speak it)."""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None

REWRITE_PROMPT = (
    "Rewrite the captured coding-agent output below as natural spoken narration "
    "for text-to-speech.\n"
    "Rules:\n"
    "- Speakable prose only: no markdown, bullets, symbols, or formatting.\n"
    "- This is a rewrite, not a summary — keep every substantive point, in order.\n"
    "- Say file and function names as plain words; skip hashes, flags, and line "
    "numbers unless they matter.\n"
    "- For code or commands, say what they do in one short phrase.\n"
    "- Output ONLY the narration. No preamble, no 'Here is', no closing remark.\n\n"
    "Captured output:\n"
)
RECAP_PROMPT = (
    "You are catching up someone who stepped away from watching this coding "
    "session. Below is the recent conversation: their requests marked 'You:' "
    "and the coding agent's replies marked 'Agent:'.\n"
    "\n"
    "FIRST, find where the story starts. You are deliberately given more history "
    "than you need, and it will usually contain earlier work that is finished and "
    "no longer relevant. Read backwards from the end and find the point where the "
    "CURRENT thread of work begins — the most recent place the person set a new "
    "direction, or where the thing still in flight was first asked for. Everything "
    "before that point is background: use it only if it explains the current work, "
    "and otherwise ignore it completely.\n"
    "\n"
    "THEN brief them on that thread, in natural spoken English:\n"
    "- where it stands RIGHT NOW, and what it is waiting on,\n"
    "- what was asked and what the agent actually did, concretely,\n"
    "- how long it has been going, if several exchanges deep.\n"
    "\n"
    "Speakable prose only: no markdown, no lists, no file paths or code. "
    "Two to five sentences. Open with the substance — no 'here is' and no "
    "restating the question. Never mention this instruction, the transcript, or "
    "that you were choosing a starting point.\n"
    "Make the FIRST sentence short — under fifteen words — and put the status "
    "in it. It is synthesized and played before the rest, so a long opening "
    "sentence is dead air.\n"
    "Output ONLY the briefing.\n\n"
    "Conversation:\n"
)
# The recap is on the critical path for time-to-first-word, so the obvious move
# is a smaller model. MEASURED, and it is the wrong move: on the same one-turn
# context, 3 runs each, haiku's median was 8.92s against sonnet's 6.96s — and
# sonnet returned MORE briefing per call. The wall clock here is dominated by
# `claude -p` process start-up, not by inference, so a cheaper model buys
# nothing and reads worse. Left on sonnet deliberately; the latency win came
# from the synth ramp and the shorter context instead (see FIRST_CHARS).
RECAP_MODEL = os.environ.get("SPEAKLOOP_RECAP_MODEL", "sonnet")
# How many request/response turns to HAND THE MODEL — deliberately more than the
# briefing needs. Picking the right number mechanically is the thing that kept
# producing edge cases: one turn could not say how you got here, and any fixed N
# is wrong the moment a task spans more or fewer exchanges than N. Where the
# story starts is a semantic boundary, not a positional one, so the model finds
# it (see RECAP_PROMPT) and this is only a generous upper bound.
#
# The window is affordable because `claude -p` wall clock is dominated by process
# start-up rather than input size — measured repeatedly on this pipeline.
RECAP_TURNS = max(1, int(os.environ.get("SPEAKLOOP_RECAP_TURNS", "12")))
# Hard ceiling on what is handed over, in characters. The newest-first budget
# rule below is now a SAFETY NET at a window this large rather than the primary
# mechanism — but it still has to exist, and still has to shed the oldest first,
# because an unbounded transcript is not passable and the newest turn is the one
# that must never be the part that gets dropped.
RECAP_BUDGET = int(os.environ.get("SPEAKLOOP_RECAP_BUDGET", "20000"))
_PREAMBLE = re.compile(
    r"\A\s*(?:sure[,!.]?\s*)?(?:here(?:'s| is)?\b[^\n:]{0,40}:|narration:)\s*", re.I)
_SENT = re.compile(r"(.+?[.!?])(?:\s+|\Z)", re.S)
_MD = re.compile(r"[`*#|>~]+")


def despeak(text: str) -> str:
    """Safety net: strip markdown artifacts a rewrite might have left behind so
    TTS never reads 'asterisk asterisk' or a backtick aloud."""
    text = re.sub(r"^\s*(?:[-*+]|\d+\.)\s+", "", text, flags=re.M)  # list markers
    return _MD.sub("", text)


def split_block(text: str, target: int = 700):
    """Break a large agent block into speakable sub-blocks on paragraph (then
    sentence) boundaries. `claude -p` runs ~20s on a 2.5k block but ~10s on a
    700-char one, so smaller pieces time out far less and pipeline better —
    piece 2 rewrites while piece 1 is already playing."""
    text = text.strip()
    if len(text) <= target:
        return [text] if text else []
    out, buf = [], ""
    for p in re.split(r"\n\s*\n", text):
        p = p.strip()
        if not p:
            continue
        if len(p) > target * 1.6:                 # giant paragraph -> by sentence
            if buf:
                out.append(buf); buf = ""
            sbuf = ""
            for s in re.split(r"(?<=[.!?])\s+", p):
                if sbuf and len(sbuf) + len(s) > target:
                    out.append(sbuf); sbuf = s
                else:
                    sbuf = (sbuf + " " + s).strip()
            if sbuf:
                out.append(sbuf)
        elif buf and len(buf) + len(p) > target:
            out.append(buf); buf = p
        else:
            buf = (buf + "\n\n" + p).strip()
    if buf:
        out.append(buf)
    return out


def _claude(prompt: str, model: str, timeout: int) -> str:
    """One `claude -p` call. Empty string on any failure/timeout."""
    try:
        out = subprocess.run(
            ["claude", "-p", "--model", model],
            input=prompt, capture_output=True, text=True, timeout=timeout,
        ).stdout.strip()
    except Exception:
        return ""
    return _PREAMBLE.sub("", out).strip()


def rewrite(text: str, model: str, timeout: int = 30) -> str:
    """Technical agent text -> comprehensible speech via `claude -p`. Empty on
    failure so the caller can skip rather than speak raw markdown."""
    return _claude(REWRITE_PROMPT + text, model, timeout)


def recap(text: str, model: str, timeout: int = 45) -> str:
    """Recent transcript -> a short spoken 'where things stand' update."""
    return _claude(RECAP_PROMPT + text, model, timeout)


def sentences(text: str):
    text = " ".join(text.split())
    pos = 0
    for m in _SENT.finditer(text):
        yield m.group(1).strip()
        pos = m.end()
    tail = text[pos:].strip()
    if tail:
        yield tail


# Group whole sentences into ~SYNTH_CHARS-sized chunks. edge-tts has ~5s of
# fixed per-call overhead, so one call per ~1KB (≈20s of audio) amortizes it;
# per-sentence synth pays that 5s on every 2-4s sentence and stutters.
SYNTH_CHARS = int(os.environ.get("SPEAKLOOP_SYNTH_CHARS", "1100"))
# The opening chunk is deliberately small so audio starts in ~2s instead of ~9s.
# 0 disables the ramp and every chunk is SYNTH_CHARS.
FIRST_CHARS = int(os.environ.get("SPEAKLOOP_FIRST_CHUNK_CHARS", "240"))
# How many blocks to rewrite in parallel. A single `claude -p` is ~20s; 2 in
# flight halves effective latency so short blocks don't drain the buffer.
REWRITE_WORKERS = max(1, int(os.environ.get("SPEAKLOOP_REWRITE_WORKERS", "2")))
# Short, clean prose is already speakable — skip the ~20s LLM for it. Anything
# with code/markdown residue or at/above this length still gets rewritten.
REWRITE_MIN_CHARS = int(os.environ.get("TTS_STREAM_REWRITE_MIN_CHARS", "160"))
_CODEY = re.compile(
    r"[`|<>{}]|https?://|/\w+/|\w+\.(?:py|js|ts|sh|md|json|txt|go|rs|c|h|yml|yaml)\b"
    r"|=>|::|\$\(|\bdef\b|\bclass\b|\bnpm\b|\bgit\b|\bsudo\b", re.I)


def synth_chunks(narr: str, target: int = SYNTH_CHARS, first: int = FIRST_CHARS):
    """Pack whole sentences into chunks — a SMALL first one, then ~target-sized.

    Time-to-first-word was the whole latency complaint. edge-tts has ~5s of fixed
    overhead and then generates roughly in proportion to length, so a 1100-char
    opening chunk means ~8-10s of silence before anything plays, even though the
    text was ready. Cutting the FIRST chunk to about a sentence gets audio out in
    ~2s; the remaining chunks stay large so the 5s overhead still amortises and
    playback does not stutter. The player is already sequential, so the big
    chunks synthesize while the short one is being spoken.
    """
    out, buf = [], ""
    limit = first if first > 0 else target
    for s in sentences(narr):
        if buf and len(buf) + len(s) + 1 > limit:
            out.append(buf)
            buf = s
            limit = target          # only the opening chunk is short
        else:
            buf = (buf + " " + s).strip()
    if buf:
        out.append(buf)
    # Sentence boundaries alone do not bound the opening chunk: a model that
    # writes one 360-character sentence hands the ramp nothing to cut on, and
    # time-to-first-word goes straight back to ~12s (measured). So if the lead
    # is still long, break it at a CLAUSE boundary — the pause is natural, and
    # the remainder simply becomes the next chunk.
    if first > 0 and out and len(out[0]) > first:
        head, tail = _split_lead(out[0], first)
        if head:
            out = [head] + ([tail] if tail else []) + out[1:]
    return out


_CLAUSE = re.compile(r"[,;:]\s|\s[—–-]\s")


def _split_lead(text: str, limit: int):
    """Cut an over-long opening chunk at the last clause break before `limit`.

    Returns (head, tail); (None, None) when there is no defensible break, in
    which case the caller keeps the long chunk rather than slicing mid-phrase —
    a cut in the wrong place is worse to listen to than a slower start.
    """
    window = text[:limit]
    cuts = [m.end() for m in _CLAUSE.finditer(window)]
    if not cuts:
        return None, None
    i = cuts[-1]
    head, tail = text[:i].strip(), text[i:].strip()
    if len(head) < 40 or not tail:      # too short to be worth a chunk of its own
        return None, None
    return head, tail


# Speaking rate. edge-tts wants a percentage like "+25%" (faster) / "-10%"
# (slower); SPEAKLOOP_RATE overrides. Default +25% per the user's preference.
SPEAK_RATE = os.environ.get("SPEAKLOOP_RATE", "+25%")


def _say_wpm(rate: str) -> str | None:
    """Convert an edge-style '+25%' rate to a `say` words-per-minute value
    (base ~175 wpm), for the fallback engine."""
    m = re.fullmatch(r"\s*([+-]?\d+)%\s*", rate or "")
    return str(int(round(175 * (1 + int(m.group(1)) / 100)))) if m else None


def synth(text: str, engine: str) -> str | None:
    """Speak `text` into an audio file; return the path."""
    suffix = ".mp3" if engine == "edge" else ".aiff"
    fd, path = tempfile.mkstemp(suffix=suffix, prefix="speakloop-")
    os.close(fd)
    try:
        if engine == "edge":
            cmd = ["edge-tts", "--voice", "en-US-AndrewNeural",
                   "--text", text, "--write-media", path]
            if SPEAK_RATE:
                cmd.append(f"--rate={SPEAK_RATE}")   # =form: safe for -NN% too
            r = subprocess.run(cmd, capture_output=True, timeout=40)
            if r.returncode == 0 and os.path.getsize(path) > 0:
                return path
        say_cmd = ["say", "-o", path]
        wpm = _say_wpm(SPEAK_RATE)
        if wpm:
            say_cmd += ["-r", wpm]
        say_cmd.append(text)
        subprocess.run(say_cmd, capture_output=True, timeout=40)
        return path if os.path.getsize(path) > 0 else None
    except Exception:
        return None


TTS_DIR = "/tmp/para-llm-tts"


def ensure_sticks() -> str | None:
    """Path to the working-heartbeat 'sticks' sound, generated once via sox (or
    reused from the file the old stream mode already made). None if unavailable."""
    override = os.environ.get("TTS_STREAM_WORKING_SOUND")
    if override and os.path.exists(override):
        return override
    sticks = os.path.join(TTS_DIR, "working-sticks.wav")
    if os.path.exists(sticks) and os.path.getsize(sticks) > 0:
        return sticks
    if not shutil.which("sox"):
        return None
    os.makedirs(TTS_DIR, exist_ok=True)
    part = sticks + ".part"
    try:
        # Same dry "sticks rubbing" texture the old stream-watcher used.
        subprocess.run(
            ["sox", "-n", "-r", "44100", "-c", "1", "-t", "wav", part,
             "synth", "0.28", "brownnoise", "tremolo", "28", "100",
             "bandpass", "2600", "1.5q", "fade", "t", "0.02", "0.28", "0.1",
             "gain", "-12"],
            capture_output=True, timeout=15)
        if os.path.getsize(part) > 0:
            os.replace(part, sticks)
            return sticks
    except Exception:
        pass
    try:
        os.unlink(part)
    except OSError:
        pass
    return None


def hook_state(cwd: str) -> str | None:
    """Claude Code's own per-session state (working/ready/blocked/ended), from
    the hook-published file keyed by cwd. None when no file exists."""
    safe = re.sub(r"^_", "", cwd.replace("/", "_"))
    try:
        data = Path(f"/tmp/claude-state/by-cwd/{safe}.json").read_text()
    except OSError:
        return None
    m = re.search(r'"state"\s*:\s*"([^"]*)"', data)
    return m.group(1) if m else None


def footer_running(pane: str) -> bool:
    """A turn is running iff Claude's bottom status bar shows 'esc to interrupt'.
    Scoped to the last few non-blank lines so scrollback can't match. This is
    the MAIN pane's turn — so subagent-only work with an idle main reads False."""
    try:
        out = subprocess.run(["tmux", "capture-pane", "-p", "-t", pane],
                             capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return False
    lines = [ln for ln in out.splitlines() if ln.strip()][-4:]
    return any("esc to interrupt" in ln for ln in lines)


def run(args) -> None:
    try:
        os.setsid()      # own process group, so a toggle can group-kill the tree
    except OSError:
        pass
    src = for_pane(args.target)
    loc = src.locate()
    print(f"[source: {src.name}]  {loc}", file=sys.stderr)
    # A transcript nobody is writing to produces exactly the symptom "it stopped
    # streaming chunks", and looks identical to a broken pipeline. Say so at
    # startup: if the file we are about to `tail -F` is already cold, the pane
    # almost certainly resolved to the wrong session.
    if loc is not None:
        try:
            age = time.time() - loc.stat().st_mtime
            if age > 600:
                print(f"[warning: that transcript was last written "
                      f"{int(age // 60)} min ago — if this pane is active, it "
                      f"resolved to the WRONG session and nothing will stream]",
                      file=sys.stderr)
        except OSError:
            pass
    # Enable moment. Live-follow only speaks blocks written AFTER this, so
    # pressing Ctrl+b o "just starts listening and plays future messages" — the
    # block the agent was already finishing as you enabled (whose write can flush
    # right at start and otherwise leak in, sounding like a recap) is skipped.
    # --backlog N is an explicit request for history and bypasses this gate.
    enable_epoch = time.time()
    only_new = os.environ.get("SPEAKLOOP_ONLY_NEW", "1") != "0"

    # Pause channel: while this file exists, hold playback and interrupt the
    # in-flight chunk (the wake-listener touches it for "pause" / dictation so
    # the mic stays clean). Path shared with the toggle via env.
    safe = args.target.lstrip("%")
    pause_file = Path(os.environ.get(
        "SPEAKLOOP_PAUSE_FILE", f"/tmp/para-speakloop/{safe}.pause"))
    # Recap channel: the wake-listener touches this on "repeat"; the recapper
    # thread turns the recent transcript into a spoken "where things stand"
    # update and jumps it to the front of playback.
    _rp = str(pause_file)
    _base = _rp[:-6] if _rp.endswith(".pause") else f"/tmp/para-speakloop/{safe}"
    repeat_file = Path(os.environ.get("SPEAKLOOP_REPEAT_FILE", _base + ".repeat"))
    # Forward ("skip", flush pending to catch up to the latest) and rewind
    # ("replay", re-speak the last block) channels. Derived from the same base
    # so the listener and this loop agree without extra env wiring.
    skip_file = Path(os.environ.get("SPEAKLOOP_SKIP_FILE", _base + ".skip"))
    replay_file = Path(os.environ.get("SPEAKLOOP_REPLAY_FILE", _base + ".replay"))
    # "cancel": stop talking and throw away everything pending — queued audio,
    # text awaiting synthesis, and blocks still being rewritten. Distinct from
    # "pause" (which holds and can resume) and from "forward" (which skips to the
    # latest). Cancel means: I do not want any of this.
    cancel_file = Path(os.environ.get("SPEAKLOOP_CANCEL_FILE", _base + ".cancel"))
    last_narr = [""]     # narration of the last completed block (for rewind)
    # Working heartbeat ("sticks"): plays while the agent is working but the
    # loop isn't speaking, so silence means "waiting for you" (or only subagents
    # are busy). Reads Claude's hook state + the live footer, same as old mode.
    spool_dir = Path(f"{TTS_DIR}/{safe}.stream")
    try:
        cwd = subprocess.run(
            ["tmux", "display-message", "-pt", args.target, "#{pane_current_path}"],
            capture_output=True, text=True, timeout=2).stdout.strip()
    except Exception:
        cwd = ""
    hb_enabled = os.environ.get("TTS_STREAM_WORKING_ENABLED", "1") != "0"
    hb_vol = os.environ.get("TTS_STREAM_WORKING_VOLUME", "1")
    try:
        hb_gap = float(os.environ.get("TTS_STREAM_WORKING_GAP", "1.1"))
    except ValueError:
        hb_gap = 1.1
    if loc is None:
        print("[no transcript for this target — nothing to tail]", file=sys.stderr)
        return

    chunk_q: "queue.Queue" = queue.Queue()
    synth_q: "queue.Queue" = queue.Queue()  # narration chunks awaiting synthesis
    audio_q: "queue.Queue" = queue.Queue()
    prio_q: "queue.Queue" = queue.Queue()   # recap audio, played before narration
    stop = threading.Event()
    speaking = threading.Event()   # true while the narration player has afplay live
    interrupt = threading.Event()  # set by cancel_speech(): stop the in-flight
                                   # chunk at once. The player clears it.
    preparing = threading.Event()  # true while the loop is generating/synthesizing
                                   # a recap or replay — the agent may be idle, but
                                   # WE are working, so the heartbeat should tick

    def feeder():
        if args.backlog > 0:
            for ch in src.backlog()[-args.backlog:]:
                chunk_q.put(ch)
        if not args.no_follow:
            print("[following live — new chunks will speak as the agent works; Ctrl+C to stop]",
                  file=sys.stderr)
            try:
                for ch in src.follow():
                    if stop.is_set():
                        break
                    # Skip a block the agent finished writing before enable (its
                    # append can flush right at start). Fail open if no timestamp.
                    if only_new and args.backlog == 0:
                        te = _ts_epoch(getattr(ch, "ts", ""))
                        if te is not None and te < enable_epoch:
                            print(f"  ⤼ skip pre-enable block ({ch.ts})", file=sys.stderr)
                            continue
                    chunk_q.put(ch)
            except Exception as e:
                print(f"[follow ended: {e}]", file=sys.stderr)
        chunk_q.put(None)

    def block_narration(text: str) -> str:
        """One agent block -> speakable narration. Short clean prose skips the
        ~20s LLM; longer/technical text is rewritten (huge blocks split first so
        no single `claude -p` prompt is enormous). Empty string on failure so the
        caller skips it — raw markdown + jargon is never spoken."""
        parts = []
        for pc in split_block(text, target=2500):
            if stop.is_set():
                break
            pt = pc.strip()
            if not pt:
                continue
            if len(pt) < REWRITE_MIN_CHARS and not _CODEY.search(pt):
                parts.append(despeak(pt))       # already speakable — no LLM
                continue
            narr = rewrite(pt, args.model, timeout=45) or rewrite(pt, args.model, timeout=75)
            if narr:
                parts.append(despeak(narr))
            else:
                print(f"  ✗ rewrite failed, skipped ({len(pt)} chars)",
                      file=sys.stderr)
        return " ".join(p for p in parts if p).strip()

    executor = ThreadPoolExecutor(max_workers=REWRITE_WORKERS)
    pending: "deque" = deque()          # futures, consumed in submission order
    pcv = threading.Condition()         # guards `pending`
    CAP = REWRITE_WORKERS + 3           # how many blocks to rewrite ahead

    def submitter():
        # Submit each block for rewrite immediately (parallel), but cap how far
        # ahead so a burst doesn't spawn unbounded `claude` processes.
        while not stop.is_set():
            ch = chunk_q.get()
            if ch is None:
                with pcv:
                    pending.append(None)        # sentinel -> collector
                    pcv.notify_all()
                return
            fut = executor.submit(block_narration, ch.text)
            with pcv:
                while len(pending) >= CAP and not stop.is_set():
                    pcv.wait(0.2)
                pending.append(fut)
                pcv.notify_all()

    def collector():
        # Consume rewrites strictly in order (even though they finish in
        # parallel) and hand ~1KB chunks to the synth stage.
        while not stop.is_set():
            with pcv:
                while not pending and not stop.is_set():
                    pcv.wait(0.2)
                if not pending:
                    continue
                fut = pending.popleft()
                pcv.notify_all()
            if fut is None:
                synth_q.put(None)
                return
            try:
                narr = fut.result()
            except Exception:
                narr = ""
            if not narr:
                continue
            g = gen[0]                          # generation this block belongs to
            last_narr[0] = narr                 # remember for "rewind"
            for c in synth_chunks(narr):
                if stop.is_set():
                    break
                if g != gen[0]:          # cancelled while this was rewriting
                    break
                print(f"  ▶ {c[:90]}", file=sys.stderr)
                synth_q.put(c)

    def synthesizer():
        # One edge-tts call per ~1KB chunk (not per sentence). Order preserved:
        # single thread, FIFO in, FIFO out.
        while not stop.is_set():
            c = synth_q.get()
            if c is None:
                audio_q.put(None)
                return
            if args.dry:
                continue
            g = gen[0]
            p = synth(c, args.engine)
            if p and g == gen[0]:     # cancelled mid-synth -> throw the audio away
                audio_q.put((p, c))   # carry the text so the player can publish
                                      # it for the mic self-echo guard

    def _render_turn(turn, per_agent: int, cap: int | None = None) -> str:
        """One request/response turn as 'You: …' / 'Agent: …'.

        When `cap` is set and the turn is over it, agent blocks are dropped from
        the FRONT — the user's request and the agent's most recent work are what
        a "where are we" briefing needs; the middle of a long turn is the part
        that can go.
        """
        user = [t for r, t in turn if r == "user"]
        agent = [t if len(t) <= per_agent else t[:per_agent] + " …"
                 for r, t in turn if r == "agent"]
        head = ["You: " + u for u in user]
        if cap is not None:
            used = sum(len(h) + 2 for h in head)
            kept: list[str] = []
            for t in reversed(agent):          # newest agent block first
                line = "Agent: " + t
                if kept and used + len(line) > cap:
                    break
                kept.append(line)
                used += len(line) + 2
            agent_lines = list(reversed(kept))
        else:
            agent_lines = ["Agent: " + t for t in agent]
        return "\n\n".join(head + agent_lines)

    def turn_context(max_turns: int = RECAP_TURNS,
                     budget: int = RECAP_BUDGET) -> str:
        """The last `max_turns` request/response turns, formatted 'You:'/'Agent:'
        so the recap can anchor on what was actually asked — not just a tail of
        the agent's last few blocks (which is how the recap 'just sucked').

        This deliberately hands over MORE than the briefing needs; the model is
        told to find where the current thread of work begins and ignore what came
        before (see RECAP_PROMPT). Choosing that boundary here, mechanically, is
        what kept producing edge cases — any fixed turn count is wrong the moment
        a task spans more or fewer exchanges than the number picked.

        The newest turn is still never the part that gets cut. An earlier version
        selected a window and truncated it with `s[:budget]`, keeping the HEAD to
        protect the anchoring 'You:'. With more than one turn that is backwards:
        the head is the OLDEST request, so the text dropped off the end was the
        agent's most recent work — which is what "repeat isn't capturing the most
        recent AI turn" was, and why it simultaneously felt like it "started way
        before we want it to". Budget is therefore spent newest-first: latest turn
        complete, older ones while they fit, then restored to order. At a window
        this size that rule is a safety net rather than the main mechanism.

        Agent turns can also be enormous (Codex especially), so each agent block
        is capped individually and user prompts are always kept in full.
        """
        try:
            events = src.recent_events(800)
        except Exception:
            events = []
        if not events:
            return ""
        ui = [i for i, (r, _) in enumerate(events) if r == "user"]
        per_agent = 1400          # cap each agent block; user prompts kept in full
        if not ui:
            # No anchor at all (a source with no reachable prompts): fall back to
            # the most recent agent blocks rather than the oldest ones in the tail.
            return _render_turn([("agent", t) for _, t in events], per_agent,
                                cap=budget)

        starts = ui[-max_turns:]
        turns = []
        for k, st in enumerate(starts):
            end = starts[k + 1] if k + 1 < len(starts) else len(events)
            turns.append(events[st:end])

        kept, used = [], 0
        for i, turn in enumerate(reversed(turns)):
            # The newest turn is rendered first and is never dropped; if it alone
            # exceeds the budget it is capped internally instead of discarded.
            block = _render_turn(turn, per_agent,
                                 cap=budget if i == 0 else None)
            if kept and used + len(block) > budget:
                break                      # older turns are the optional part
            kept.append(block)
            used += len(block) + 2
        return "\n\n".join(reversed(kept))

    def enqueue_prio(text: str, marker: str):
        g = gen[0]
        for c in synth_chunks(despeak(text)):
            if stop.is_set() or g != gen[0]:
                break
            print(f"  {marker} {c[:90]}", file=sys.stderr)
            if args.dry:
                continue
            a = synth(c, args.engine)
            if a and g == gen[0]:
                prio_q.put((a, c))

    # Generation counter for "cancel". Draining the queues only removes work that
    # has already been produced; a rewrite or a synth already in flight would land
    # in the queue a moment later and start talking again. Every producer captures
    # the generation it started under and drops its result if `gen` has moved —
    # so "cancel" cancels the REQUESTS, not just the backlog.
    gen = [0]

    def cancel_all(reason: str):
        """Everything stops: current audio, queued audio, and pending TTS work."""
        gen[0] += 1
        interrupt.set()
        n = drain(prio_q) + drain(audio_q) + drain(synth_q) + drain(chunk_q)
        print(f"  ⛔ cancel ({reason}): dropped {n} queued item(s), "
              f"generation now {gen[0]}", file=sys.stderr)

    def cancel_speech():
        """Stop talking NOW and drop everything queued.

        "Repeat" means "get me up to speed on where we are, now". Queueing a
        fresh recap behind narration that is already playing — or behind a recap
        the previous Ctrl+b o started — makes the listener sit through stale
        audio to reach the thing they just asked for. So a repeat preempts:
        interrupt the current chunk, bin both queues, then build the new one.
        Draining BEFORE synthesis is what keeps the new recap from being eaten
        by its own flush.
        """
        interrupt.set()
        n = drain(prio_q) + drain(audio_q)
        if n:
            print(f"  ✂ cancelled {n} queued chunk(s)", file=sys.stderr)

    def controller():
        # Voice-command channels that produce priority (jump-the-queue) audio:
        #   repeat -> spoken "where things stand" recap of the recent transcript
        #   rewind -> replay the last block's narration verbatim
        while not stop.is_set():
            if cancel_file.exists():
                try:
                    cancel_file.unlink()
                except OSError:
                    pass
                # Checked before repeat/replay on purpose: if both are pending,
                # "cancel" is the later intent and must not be undone by a recap
                # that was already queued.
                cancel_all("voice command")
            elif repeat_file.exists():
                try:
                    repeat_file.unlink()
                except OSError:
                    pass
                cancel_speech()   # preempt: a recap is always about NOW
                preparing.set()   # keep the heartbeat ticking through the LLM
                try:              # + first synth so the wait isn't dead silence
                    ctx = turn_context()
                    if ctx:
                        print("  ⟳ recap requested", file=sys.stderr)
                        # Shorter than the old 60/90. On one turn of context a
                        # haiku recap lands in ~2-3s; a 60s first attempt only
                        # meant a stall cost 150s before you heard the failure.
                        narr = recap(ctx, RECAP_MODEL, timeout=25) \
                            or recap(ctx, RECAP_MODEL, timeout=40)
                        if narr:
                            enqueue_prio(narr, "⟳")
                        else:
                            print("  ✗ recap failed", file=sys.stderr)
                finally:
                    preparing.clear()
            elif replay_file.exists():
                try:
                    replay_file.unlink()
                except OSError:
                    pass
                cancel_speech()          # same preempt rule as repeat
                preparing.set()
                try:
                    if last_narr[0]:
                        print("  ↺ replay last block", file=sys.stderr)
                        enqueue_prio(last_narr[0], "↺")
                    else:
                        print("  ↺ replay: nothing spoken yet", file=sys.stderr)
                finally:
                    preparing.clear()
            else:
                time.sleep(0.3)

    def drain(q: "queue.Queue") -> int:
        n = 0
        while True:
            try:
                item = q.get_nowait()
            except queue.Empty:
                break
            if item:
                path = item[0] if isinstance(item, tuple) else item
                try:
                    os.unlink(path)
                except OSError:
                    pass
            n += 1
        return n

    # Mic self-echo guard: the TTS plays through the speakers, the mic hears it,
    # and a magic word in the narration ("window", "send") would actuate. We
    # publish the text we're saying RIGHT NOW to a file the wake-listener reads;
    # it drops a command word only while that word is actually audible. Publish
    # just the CURRENT chunk — keeping older chunks made the guard suppress a
    # command for ~40s of narration history, which false-blocked common words
    # like "send" when the agent was building a messaging feature.
    tts_speaking_file = spool_dir / "tts.speaking"

    def publish_speaking(text: str):
        try:
            spool_dir.mkdir(parents=True, exist_ok=True)
            tts_speaking_file.write_text(" ".join(text.split()).lower())
        except OSError:
            pass

    def player():
        while not stop.is_set():
            # A cancel that arrived while nothing was playing still has to be
            # consumed, or it would kill the very chunk it made room for.
            interrupt.clear()
            while pause_file.exists() and not stop.is_set():
                time.sleep(0.12)
            # "forward": drop the pending narration so we jump to the latest.
            # (prio_q recaps/replays are intentional and survive a skip.)
            if skip_file.exists():
                try:
                    skip_file.unlink()
                except OSError:
                    pass
                drain(audio_q)
            # A recap/replay (prio_q) preempts pending narration; we check it
            # before each sentence, so "repeat"/"rewind" is heard right away.
            try:
                item = prio_q.get_nowait()
            except queue.Empty:
                try:
                    item = audio_q.get(timeout=0.3)
                except queue.Empty:
                    continue
            if item is None:            # worker done
                if args.no_follow:
                    return
                continue
            p, text = item
            if not stop.is_set():
                speaking.set()             # mute the heartbeat while we talk
                publish_speaking(text)     # ...and tell the mic listener what we say
                proc = subprocess.Popen(["afplay", p],
                                        stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
                last_touch = 0.0
                while proc.poll() is None:
                    if (stop.is_set() or pause_file.exists()
                            or skip_file.exists() or interrupt.is_set()):
                        proc.terminate()   # interrupt current chunk on pause/skip/cancel
                        break
                    now = time.time()
                    if now - last_touch > 0.4:
                        try:
                            os.utime(tts_speaking_file, None)  # keep "speaking" fresh
                        except OSError:
                            pass
                        last_touch = now
                    time.sleep(0.08)
                speaking.clear()
            try:
                os.unlink(p)
            except OSError:
                pass

    def voice_active() -> bool:
        try:
            return (time.time() - (spool_dir / "voice.active").stat().st_mtime) < 3
        except OSError:
            return False

    _wk = {"t": 0.0, "v": False}

    def is_working() -> bool:
        now = time.time()
        if now - _wk["t"] > 0.7:          # throttle the capture-pane check
            # hook_state reads Claude Code's per-cwd state file. Only trust it for
            # a Claude pane: a Codex pane in a worktree that once ran Claude finds
            # a STALE file (e.g. state "ended"), which would wrongly force the
            # heartbeat off. For Codex, the footer ("esc to interrupt") is the
            # signal. (BUG: Codex heartbeat silent.)
            st = hook_state(cwd) if (cwd and src.name == "claude") else None
            _wk["v"] = False if st in ("blocked", "ended") else footer_running(args.target)
            _wk["t"] = now
        return _wk["v"]

    def heartbeat():
        # Sticks while the agent is working and we're not speaking; silent when
        # it's the user's turn (or only subagents are busy).
        if not hb_enabled or args.dry:
            return
        sticks = ensure_sticks()
        if not sticks:
            print("[heartbeat: no sticks sound (sox missing?) — off]", file=sys.stderr)
            return

        def wanted() -> bool:
            # Tick while the agent is working OR we're preparing a recap/replay
            # (agent may be idle then, but the user should hear we're on it),
            # unless we're already speaking / paused / the mic is live.
            return (not pause_file.exists() and not speaking.is_set()
                    and not voice_active()
                    and (is_working() or preparing.is_set()))

        while not stop.is_set():
            if wanted():
                proc = subprocess.Popen(["afplay", "-v", hb_vol, sticks],
                                        stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
                while proc.poll() is None:
                    if stop.is_set() or not wanted():
                        proc.terminate()
                        break
                    time.sleep(0.05)
                time.sleep(hb_gap)
            else:
                time.sleep(0.25)

    def ownership():
        """Stop the moment this pane is no longer the one speak mode owns.

        THE LOOP HAD NO OWNERSHIP CHECK AT ALL. The wake-listener has always had
        one (`while mode_active`, comparing stream.pane to its own pane), but the
        narration loop only ever stopped when something killed it — and
        toggle-speak's read-PREV / evict / claim sequence is not atomic. Two
        overlapping hand-offs both read the same previous owner, both evict it,
        and both survive; whichever writes stream.pane last gets the purple pane
        while the other keeps narrating into the room. That is the "playback for
        sessions I'm not selected to" report, and repeating a command that seemed
        not to work is exactly what produces the overlap.

        Making the loop responsible for its own liveness closes it for good: a
        missed eviction, a lost race, a crashed teardown — whatever the cause, a
        loop that does not own stream.pane exits on its own within a second.

        An ABSENT stream.pane means nobody has claimed the mode (whisper missing,
        or the file was cleared by our own eviction), which is NOT a reason to
        die — only a file naming a DIFFERENT pane is. The grace period covers
        startup, where toggle-speak writes the claim moments after launching us.
        """
        grace = time.time() + 8.0
        while not stop.is_set():
            try:
                owner = Path(TTS_DIR, "stream.pane").read_text().strip()
            except OSError:
                owner = ""
            if owner and owner != safe:
                if time.time() > grace:
                    print(f"  ⨯ pane %{safe} no longer owns speak mode "
                          f"(now %{owner}) — stopping", file=sys.stderr)
                    stop.set()
                    with pcv:
                        pcv.notify_all()
                    return
            elif owner == safe:
                grace = 0.0          # claim seen; enforce strictly from now on
            time.sleep(0.5)

    tf = threading.Thread(target=feeder, daemon=True)
    tsub = threading.Thread(target=submitter, daemon=True)
    tcol = threading.Thread(target=collector, daemon=True)
    tsyn = threading.Thread(target=synthesizer, daemon=True)
    tp = threading.Thread(target=player, daemon=True)
    tr = threading.Thread(target=controller, daemon=True)
    th = threading.Thread(target=heartbeat, daemon=True)
    town = threading.Thread(target=ownership, daemon=True)
    for t in (tf, tsub, tcol, tsyn, tp, tr, th, town):
        t.start()
    try:
        if args.no_follow:
            tsyn.join()        # ends after the None sentinel propagates through
            tp.join(timeout=120)
        else:
            tp.join()          # follow mode runs until Ctrl+C
    except KeyboardInterrupt:
        print("\n[stopped]", file=sys.stderr)
    finally:
        stop.set()
        with pcv:              # wake submitter/collector out of their waits
            pcv.notify_all()
        executor.shutdown(wait=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target", help="tmux pane id (%%N) or a cwd")
    ap.add_argument("--backlog", type=int, default=0,
                    help="speak the last N existing chunks before following")
    ap.add_argument("--no-follow", action="store_true",
                    help="only the backlog, then exit (bounded run)")
    ap.add_argument("--model", default="haiku")
    ap.add_argument("--engine", default="edge", choices=["edge", "say"])
    ap.add_argument("--dry", action="store_true",
                    help="print narration only; no synth/play")
    run(ap.parse_args())


if __name__ == "__main__":
    main()
