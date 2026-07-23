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
_PREAMBLE = re.compile(
    r"\A\s*(?:sure[,!.]?\s*)?(?:here(?:'s| is)?\b[^\n:]{0,40}:|narration:)\s*", re.I)
_SENT = re.compile(r"(.+?[.!?])(?:\s+|\Z)", re.S)


def rewrite(text: str, model: str, timeout: int = 30) -> str:
    """Technical agent text -> comprehensible speech via `claude -p`. Empty on
    failure so the caller can fall back to the raw text."""
    try:
        out = subprocess.run(
            ["claude", "-p", "--model", model],
            input=REWRITE_PROMPT + text,
            capture_output=True, text=True, timeout=timeout,
        ).stdout.strip()
    except Exception:
        return ""
    return _PREAMBLE.sub("", out).strip()


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
    src = for_pane(args.target)
    loc = src.locate()
    print(f"[source: {src.name}]  {loc}", file=sys.stderr)
    if loc is None:
        print("[no transcript for this target — nothing to tail]", file=sys.stderr)
        return

    chunk_q: "queue.Queue" = queue.Queue()
    audio_q: "queue.Queue" = queue.Queue()
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
            narr = rewrite(ch.text, args.model) or ch.text
            for s in sentences(narr):
                if stop.is_set():
                    break
                print(f"  ▶ {s}", file=sys.stderr)
                if args.dry:
                    continue
                p = synth(s, args.engine)
                if p:
                    audio_q.put(p)

    def player():
        while True:
            p = audio_q.get()
            if p is None:
                return
            if not stop.is_set():
                subprocess.run(["afplay", p], capture_output=True)
            try:
                os.unlink(p)
            except OSError:
                pass

    tf = threading.Thread(target=feeder, daemon=True)
    tw = threading.Thread(target=worker, daemon=True)
    tp = threading.Thread(target=player, daemon=True)
    for t in (tf, tw, tp):
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
