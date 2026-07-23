#!/usr/bin/env python3
"""
agent_source.py — a framework-agnostic source of an agent's spoken-worthy text.

Instead of polling the terminal screen, each REPL framework exposes its output
through a per-session transcript it appends AS IT WORKS. This wraps those
transcripts behind one interface (AgentSource) so the speak-mode pipeline
(FIFO -> LLM rewrite -> synth -> play) never has to know which REPL is in the
pane.

    ClaudeCodeSource  tails ~/.claude/projects/<enc-cwd>/<session>.jsonl
    CodexSource       tails ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
    PollingSource     fallback for REPLs with no transcript (capture-pane) [stub]

Each yields TextChunk objects as complete assistant text blocks land. Those
blocks are already complete-idea boundaries (prose written, then a tool call) —
no ANSI, no chrome, no viewport/scroll-off loss.

Demo:  python3 agent_source.py <pane_id | cwd>
       python3 agent_source.py --codex     # newest codex rollout
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Optional


@dataclass
class TextChunk:
    text: str
    ts: str = ""
    source: str = ""
    kind: str = "text"          # text | thinking


class AgentSource(ABC):
    """One REPL's transcript, tailed. Subclasses supply locate() + extract()."""
    name = "?"

    @abstractmethod
    def locate(self) -> Optional[Path]:
        """The active session transcript file, or None."""

    @abstractmethod
    def extract(self, obj: dict) -> Iterator[TextChunk]:
        """Pull assistant text block(s) out of one parsed JSONL record."""

    def backlog(self, n: int = 500) -> list[TextChunk]:
        """Text blocks already written (last n records) — for resume/recap."""
        p = self.locate()
        if not p:
            return []
        try:
            raw = subprocess.run(["tail", "-n", str(n), str(p)],
                                 capture_output=True, text=True, errors="replace").stdout
        except Exception:
            return []
        return [c for line in raw.splitlines() if line.strip()
                for c in self._parse(line)]

    def follow(self) -> Iterator[TextChunk]:
        """Yield text blocks as they are appended — the OS does the follow."""
        p = self.locate()
        if not p:
            return
        proc = subprocess.Popen(["tail", "-n", "0", "-F", str(p)],
                                stdout=subprocess.PIPE, text=True)
        try:
            for line in proc.stdout:            # blocks until the file grows
                yield from self._parse(line)
        finally:
            proc.terminate()

    def _parse(self, line: str) -> Iterator[TextChunk]:
        line = line.strip()
        if not line:
            return
        try:
            obj = json.loads(line)
        except Exception:
            return
        yield from self.extract(obj)


class ClaudeCodeSource(AgentSource):
    name = "claude"

    def __init__(self, cwd: str):
        self.cwd = cwd

    def _project_dir(self) -> Path:
        # Claude Code encodes the cwd into the project dir: '/' and '.' -> '-'.
        enc = re.sub(r"[/.]", "-", self.cwd)
        return Path.home() / ".claude" / "projects" / enc

    def locate(self) -> Optional[Path]:
        d = self._project_dir()
        if not d.is_dir():
            return None
        files = sorted(d.glob("*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)
        return files[0] if files else None

    def extract(self, o: dict) -> Iterator[TextChunk]:
        if o.get("type") != "assistant":
            return
        for c in ((o.get("message") or {}).get("content") or []):
            if isinstance(c, dict) and c.get("type") == "text" and (c.get("text") or "").strip():
                yield TextChunk(c["text"].strip(), o.get("timestamp", ""), self.name)


class CodexSource(AgentSource):
    name = "codex"

    def __init__(self, cwd: Optional[str] = None):
        self.cwd = cwd

    def locate(self) -> Optional[Path]:
        base = Path.home() / ".codex" / "sessions"
        if not base.is_dir():
            return None
        files = sorted(base.glob("**/rollout-*.jsonl"),
                       key=lambda f: f.stat().st_mtime, reverse=True)
        if not files:
            return None
        # Codex paths are date-keyed, not cwd-keyed; prefer a rollout whose
        # session_meta names our cwd, else the newest.
        if self.cwd:
            for f in files:
                try:
                    if self.cwd in f.open().readline():
                        return f
                except Exception:
                    pass
        return files[0]

    def extract(self, o: dict) -> Iterator[TextChunk]:
        if o.get("type") != "response_item":
            return
        p = o.get("payload") or {}
        if p.get("role") != "assistant":
            return
        for c in (p.get("content") or []):
            if isinstance(c, dict) and c.get("type") in ("output_text", "text") and (c.get("text") or "").strip():
                yield TextChunk(c["text"].strip(), o.get("timestamp", ""), self.name)


class PollingSource(AgentSource):
    """Fallback for REPLs with no transcript: capture-pane + filter + settle.
    Stubbed here — the point of the prototype is to *retire* this path where a
    transcript exists."""
    name = "poll"

    def __init__(self, pane_id: str):
        self.pane_id = pane_id

    def locate(self):
        return None

    def extract(self, o):
        return iter(())

    def follow(self):
        raise NotImplementedError("polling fallback not implemented in prototype")


def _tmux(pane_id: str, fmt: str) -> str:
    try:
        return subprocess.check_output(
            ["tmux", "display-message", "-pt", pane_id, fmt], text=True).strip()
    except Exception:
        return ""


def for_pane(pane_or_cwd: str) -> AgentSource:
    """Pick the right adapter for a pane id (%N) or a raw cwd. Prefers whichever
    framework has a live transcript for this cwd; polling only if none does."""
    if pane_or_cwd.startswith("%"):
        cwd = _tmux(pane_or_cwd, "#{pane_current_path}")
    else:
        cwd = pane_or_cwd
    cc = ClaudeCodeSource(cwd)
    if cc.locate():
        return cc
    cx = CodexSource(cwd)
    if cx.locate():
        return cx
    return PollingSource(pane_or_cwd)


def _demo(src: AgentSource) -> None:
    loc = src.locate()
    print(f"[source: {src.name}]  transcript: {loc}", file=sys.stderr)
    back = src.backlog()
    print(f"[backlog: {len(back)} text blocks — last 3:]", file=sys.stderr)
    for ch in back[-3:]:
        one = " ".join(ch.text.split())
        print(f"   • {one[:110]}", file=sys.stderr)
    print("[following — new complete-idea chunks print below as the agent works]\n",
          file=sys.stderr)
    for ch in src.follow():
        print(f"── {src.name} chunk @ {ch.ts} ──\n{ch.text}\n", flush=True)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: agent_source.py <pane_id | cwd | --codex>", file=sys.stderr)
        sys.exit(2)
    arg = sys.argv[1]
    src = CodexSource() if arg == "--codex" else for_pane(arg)
    _demo(src)
