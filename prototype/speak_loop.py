#!/usr/bin/env python3
"""
speak_loop.py — the end-to-end tail -> rewrite -> speak loop (prototype).

Pipeline, all stages concurrent with queues between them:

    AgentSource.follow()          # tail the transcript (no screen polling)
        -> chunk_q                # one complete-idea text block per item
        -> rewrite + synth worker # LLM makes it speakable, split to sentences,
                                  #   synthesize each
        -> audio_q                # audio files, in order
        -> play worker            # afplay, strictly sequenced

Rewriting chunk N overlaps playing chunk N-1, so the LLM latency hides behind
playback. Each chunk is already a complete idea (a prose block the agent wrote
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
import subprocess
import sys
import tempfile
import threading
import time
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


def synth(text: str, engine: str) -> str | None:
    """Speak `text` into an audio file; return the path."""
    suffix = ".mp3" if engine == "edge" else ".aiff"
    fd, path = tempfile.mkstemp(suffix=suffix, prefix="speakloop-")
    os.close(fd)
    try:
        if engine == "edge":
            r = subprocess.run(
                ["edge-tts", "--voice", "en-US-AndrewNeural",
                 "--text", text, "--write-media", path],
                capture_output=True, timeout=40)
            if r.returncode == 0 and os.path.getsize(path) > 0:
                return path
        subprocess.run(["say", "-o", path, text], capture_output=True, timeout=40)
        return path if os.path.getsize(path) > 0 else None
    except Exception:
        return None


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
    repeat_file = Path(os.environ.get(
        "SPEAKLOOP_REPEAT_FILE",
        _rp[:-6] + ".repeat" if _rp.endswith(".pause")
        else f"/tmp/para-speakloop/{safe}.repeat"))
    if loc is None:
        print("[no transcript for this target — nothing to tail]", file=sys.stderr)
        return

    chunk_q: "queue.Queue" = queue.Queue()
    audio_q: "queue.Queue" = queue.Queue()
    prio_q: "queue.Queue" = queue.Queue()   # recap audio, played before narration
    stop = threading.Event()

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

    def worker():
        while not stop.is_set():
            ch = chunk_q.get()
            if ch is None:
                audio_q.put(None)
                return
            for sub in split_block(ch.text):
                if stop.is_set():
                    break
                narr = rewrite(sub, args.model, timeout=45)
                if not narr:
                    narr = rewrite(sub, args.model, timeout=75)  # retry, more time
                if not narr:
                    # Never speak raw agent text — it's markdown + jargon, not
                    # speech. Silence beats gibberish; the block is still on
                    # screen to read.
                    print(f"  ✗ rewrite failed, skipped ({len(sub)} chars)",
                          file=sys.stderr)
                    continue
                narr = despeak(narr)
                for s in sentences(narr):
                    if stop.is_set():
                        break
                    print(f"  ▶ {s}", file=sys.stderr)
                    if args.dry:
                        continue
                    p = synth(s, args.engine)
                    if p:
                        audio_q.put(p)

    def recent_transcript(limit_chars: int = 3500, blocks: int = 6) -> str:
        try:
            recent = src.backlog(80)[-blocks:]
        except Exception:
            recent = []
        return "\n\n".join(c.text for c in recent).strip()[-limit_chars:]

    def recapper():
        # "repeat" -> spoken "where things stand" from the recent transcript.
        while not stop.is_set():
            if not repeat_file.exists():
                time.sleep(0.3)
                continue
            try:
                repeat_file.unlink()
            except OSError:
                pass
            ctx = recent_transcript()
            if not ctx:
                continue
            print("  ⟳ recap requested", file=sys.stderr)
            narr = recap(ctx, args.model) or recap(ctx, args.model, timeout=75)
            if not narr:
                print("  ✗ recap failed", file=sys.stderr)
                continue
            for s in sentences(despeak(narr)):
                if stop.is_set():
                    break
                print(f"  ⟳ {s}", file=sys.stderr)
                if args.dry:
                    continue
                a = synth(s, args.engine)
                if a:
                    prio_q.put(a)

    def player():
        while not stop.is_set():
            while pause_file.exists() and not stop.is_set():
                time.sleep(0.12)
            # A recap (prio_q) preempts pending narration; we check it before
            # each sentence, so "repeat" is heard within one sentence.
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
                proc = subprocess.Popen(["afplay", p],
                                        stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
                while proc.poll() is None:
                    if stop.is_set() or pause_file.exists():
                        proc.terminate()   # interrupt current chunk on pause
                        break
                    time.sleep(0.08)
            try:
                os.unlink(p)
            except OSError:
                pass

    tf = threading.Thread(target=feeder, daemon=True)
    tw = threading.Thread(target=worker, daemon=True)
    tp = threading.Thread(target=player, daemon=True)
    tr = threading.Thread(target=recapper, daemon=True)
    for t in (tf, tw, tp, tr):
        t.start()
    try:
        tw.join()          # ends on the None sentinel
        tp.join(timeout=60)
    except KeyboardInterrupt:
        stop.set()
        print("\n[stopped]", file=sys.stderr)


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
