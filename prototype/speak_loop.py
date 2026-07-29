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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agent_source import for_pane  # noqa: E402

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
    "Someone stepped away from watching this coding session and just asked "
    "'where do things stand?'. From the recent agent transcript below, give "
    "them a short spoken update.\n"
    "Say, in 2 to 4 sentences of natural spoken English:\n"
    "- what the agent is working on right now,\n"
    "- what it just finished or concluded,\n"
    "- and what's next or what it's waiting on.\n"
    "Speakable prose only: no markdown, no lists, no file paths or code unless "
    "essential. Present tense, oriented to 'here's where we are'. "
    "Output ONLY the update.\n\n"
    "Recent transcript:\n"
)
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
# How many blocks to rewrite in parallel. A single `claude -p` is ~20s; 2 in
# flight halves effective latency so short blocks don't drain the buffer.
REWRITE_WORKERS = max(1, int(os.environ.get("SPEAKLOOP_REWRITE_WORKERS", "2")))
# Short, clean prose is already speakable — skip the ~20s LLM for it. Anything
# with code/markdown residue or at/above this length still gets rewritten.
REWRITE_MIN_CHARS = int(os.environ.get("TTS_STREAM_REWRITE_MIN_CHARS", "160"))
_CODEY = re.compile(
    r"[`|<>{}]|https?://|/\w+/|\w+\.(?:py|js|ts|sh|md|json|txt|go|rs|c|h|yml|yaml)\b"
    r"|=>|::|\$\(|\bdef\b|\bclass\b|\bnpm\b|\bgit\b|\bsudo\b", re.I)


def synth_chunks(narr: str, target: int = SYNTH_CHARS):
    """Pack whole sentences into ~target-char chunks for one synth call each."""
    out, buf = [], ""
    for s in sentences(narr):
        if buf and len(buf) + len(s) + 1 > target:
            out.append(buf)
            buf = s
        else:
            buf = (buf + " " + s).strip()
    if buf:
        out.append(buf)
    return out


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
            last_narr[0] = narr                 # remember for "rewind"
            for c in synth_chunks(narr):
                if stop.is_set():
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
            p = synth(c, args.engine)
            if p:
                audio_q.put(p)

    def recent_transcript(limit_chars: int = 3500, blocks: int = 6) -> str:
        try:
            recent = src.backlog(80)[-blocks:]
        except Exception:
            recent = []
        return "\n\n".join(c.text for c in recent).strip()[-limit_chars:]

    def enqueue_prio(text: str, marker: str):
        for c in synth_chunks(despeak(text)):
            if stop.is_set():
                break
            print(f"  {marker} {c[:90]}", file=sys.stderr)
            if args.dry:
                continue
            a = synth(c, args.engine)
            if a:
                prio_q.put(a)

    def controller():
        # Voice-command channels that produce priority (jump-the-queue) audio:
        #   repeat -> spoken "where things stand" recap of the recent transcript
        #   rewind -> replay the last block's narration verbatim
        while not stop.is_set():
            if repeat_file.exists():
                try:
                    repeat_file.unlink()
                except OSError:
                    pass
                ctx = recent_transcript()
                if ctx:
                    print("  ⟳ recap requested", file=sys.stderr)
                    narr = recap(ctx, args.model) or recap(ctx, args.model, timeout=75)
                    if narr:
                        enqueue_prio(narr, "⟳")
                    else:
                        print("  ✗ recap failed", file=sys.stderr)
            elif replay_file.exists():
                try:
                    replay_file.unlink()
                except OSError:
                    pass
                if last_narr[0]:
                    print("  ↺ replay last block", file=sys.stderr)
                    enqueue_prio(last_narr[0], "↺")
                else:
                    print("  ↺ replay: nothing spoken yet", file=sys.stderr)
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
                try:
                    os.unlink(item)
                except OSError:
                    pass
            n += 1
        return n

    def player():
        while not stop.is_set():
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
                p = prio_q.get_nowait()
            except queue.Empty:
                try:
                    p = audio_q.get(timeout=0.3)
                except queue.Empty:
                    continue
            if p is None:               # worker done
                if args.no_follow:
                    return
                continue
            if not stop.is_set():
                speaking.set()             # mute the heartbeat while we talk
                proc = subprocess.Popen(["afplay", p],
                                        stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
                while proc.poll() is None:
                    if stop.is_set() or pause_file.exists() or skip_file.exists():
                        proc.terminate()   # interrupt current chunk on pause/skip
                        break
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
            st = hook_state(cwd) if cwd else None
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
            return (not pause_file.exists() and not speaking.is_set()
                    and not voice_active() and is_working())

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

    tf = threading.Thread(target=feeder, daemon=True)
    tsub = threading.Thread(target=submitter, daemon=True)
    tcol = threading.Thread(target=collector, daemon=True)
    tsyn = threading.Thread(target=synthesizer, daemon=True)
    tp = threading.Thread(target=player, daemon=True)
    tr = threading.Thread(target=controller, daemon=True)
    th = threading.Thread(target=heartbeat, daemon=True)
    for t in (tf, tsub, tcol, tsyn, tp, tr, th):
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
