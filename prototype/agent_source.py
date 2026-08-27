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

    # System-injected "user" records — task-completion notifications, slash
    # command echoes, hook output — are not things the person typed. A recap
    # must anchor on REAL requests, so these are skipped when building turns.
    # Two shapes leak past a "starts with <tag>" test, and both were observed
    # anchoring a recap on something the person never said:
    #   "Base directory for this skill: /private/tmp/.../claude-api  ## ..."
    #   "Another Claude session sent a message: <cross-session-message from=..."
    # Neither begins with a tag — they begin with prose — so the recap opened on
    # a skill dump or another session's chatter instead of the real request.
    # Hence: match a known tag ANYWHERE in the opening stretch, plus the two
    # prose preambles by name.
    _SYS_USER = re.compile(
        r"^\s*(?:"
        r"<(?:task-notification|command-name|command-message|command-args|"
        r"local-command|system-reminder|user-prompt-submit-hook|"
        r"cross-session-message)"
        r"|Base directory for this skill:"
        r"|Another Claude session sent a message"
        r"|Caveat: The messages below were generated"
        r")", re.I)
    _SYS_USER_ANYWHERE = re.compile(
        r"<(?:task-notification|cross-session-message|local-command|"
        r"user-prompt-submit-hook)\b", re.I)

    @classmethod
    def _is_system_user(cls, txt: str) -> bool:
        """True when a `user` record is machine-injected, not typed by a person.

        Checked against the head of the text as well as the start: a peer message
        or a task notification can arrive with a sentence of framing in front of
        it, and an anchor is only useful if it lands on a REAL request.
        """
        return bool(cls._SYS_USER.match(txt)
                    or cls._SYS_USER_ANYWHERE.search(txt[:400]))

    def recent_events(self, n: int = 800) -> "list[tuple[str, str]]":
        """Recent (role, text) events in order — for a turn-aware catch-up recap
        that can say 'you asked X; the agent did Y'. Base implementation has only
        agent text (from backlog); sources with reachable user prompts override
        to interleave 'user' events for anchoring."""
        return [("agent", ch.text) for ch in self.backlog(n)]

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

    def recent_events(self, n: int = 800) -> "list[tuple[str, str]]":
        p = self.locate()
        if not p:
            return []
        try:
            raw = subprocess.run(["tail", "-n", str(n), str(p)],
                                 capture_output=True, text=True, errors="replace").stdout
        except Exception:
            return []
        ev: "list[tuple[str, str]]" = []
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            t = o.get("type")
            if t == "assistant":
                for c in ((o.get("message") or {}).get("content") or []):
                    if isinstance(c, dict) and c.get("type") == "text" and (c.get("text") or "").strip():
                        ev.append(("agent", " ".join(c["text"].split())))
            elif t == "user":
                c = (o.get("message") or {}).get("content")
                if isinstance(c, str):
                    txt = c
                elif isinstance(c, list):
                    txt = " ".join(i.get("text", "") for i in c
                                   if isinstance(i, dict) and i.get("type") == "text")
                else:
                    txt = ""
                txt = " ".join(txt.split())
                if txt and not self._is_system_user(txt):   # skip tool_results + system injections
                    ev.append(("user", txt))
        return ev


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

    # Codex injects its own preambles as `user` records. The XML-ish ones
    # (<environment_context>, <turn_aborted>, …) are caught by the leading-"<"
    # test below, but the AGENTS.md block it is handed at session start opens
    # with "# AGENTS.md instructions for /Users/…" — prose, not a tag — and was
    # counting as a real request. Same rule as ClaudeCodeSource: an anchor is
    # only useful when it lands on something a person actually typed.
    _CODEX_SYS_USER = re.compile(
        r"^\s*(?:<(?:INSTRUCTIONS|environment_context|user_instructions)"
        r"|#\s*AGENTS\.md instructions for)", re.I)

    def recent_events(self, n: int = 800) -> "list[tuple[str, str]]":
        """Interleave real user prompts with agent text so the catch-up recap can
        anchor on 'you asked X'. Codex user messages are input_text; the XML-ish
        ones (<environment_context>, <turn_aborted>, …) are system injections, not
        things the person typed, so they're skipped — the plain-text ones are the
        real prompts.

        Codex rollouts interleave ~16 noise records (token_count, event_msg,
        reasoning) per message, so the last couple of user turns sit ~900+ lines
        deep. A Claude-sized tail (800) never reaches them and the recap loses its
        anchor — so read a much larger window here."""
        p = self.locate()
        if not p:
            return []
        n = max(n, 8000)
        try:
            raw = subprocess.run(["tail", "-n", str(n), str(p)],
                                 capture_output=True, text=True, errors="replace").stdout
        except Exception:
            return []
        ev: "list[tuple[str, str]]" = []
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("type") != "response_item":
                continue
            pl = o.get("payload") or {}
            if pl.get("type") != "message":
                continue
            role = pl.get("role")
            if role == "assistant":
                for c in (pl.get("content") or []):
                    if isinstance(c, dict) and c.get("type") in ("output_text", "text") and (c.get("text") or "").strip():
                        ev.append(("agent", " ".join(c["text"].split())))
            elif role == "user":
                txt = " ".join(c.get("text", "") for c in (pl.get("content") or [])
                               if isinstance(c, dict) and c.get("type") == "input_text")
                txt = " ".join(txt.split())
                # Two filters, not one: the leading "<" catches the XML-ish
                # injections, _CODEX_SYS_USER catches the AGENTS.md preamble that
                # opens with "#" and slipped through as a real request.
                if (txt and not txt.lstrip().startswith("<")
                        and not self._CODEX_SYS_USER.match(txt)):
                    ev.append(("user", txt))
        return ev


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


def _repl_in_pane(pane_id: str) -> Optional[str]:
    """Which REPL is actually RUNNING in this pane — 'claude' or 'codex' — from
    the pane's process tree. This is authoritative; a transcript folder merely
    existing is not (a worktree that once ran Claude keeps its
    ~/.claude/projects/<cwd> dir forever, which would otherwise mis-route a Codex
    pane to that stale, ended Claude transcript). Returns None if inconclusive."""
    pane_pid = _tmux(pane_id, "#{pane_pid}")
    if not pane_pid:
        return None
    try:
        out = subprocess.run(["ps", "-o", "pid=,ppid=,command=", "-ax"],
                             capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return None
    # Build child lists and walk down from the pane's shell, matching the first
    # descendant whose command names a known REPL.
    children: "dict[str, list[tuple[str, str]]]" = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, ppid, cmd = parts
        children.setdefault(ppid, []).append((pid, cmd))
    seen, stack = set(), [pane_pid]
    while stack:
        cur = stack.pop()
        for pid, cmd in children.get(cur, []):
            if pid in seen:
                continue
            seen.add(pid)
            low = cmd.lower()
            # word-ish match so a path like /opt/homebrew/bin/codex counts but a
            # cwd argument mentioning the name does not dominate the decision.
            if re.search(r"(?:^|/)codex(?:\s|$)", low) or " codex " in f" {low} ":
                return "codex"
            if re.search(r"(?:^|/)claude(?:\s|$)", low) or " claude " in f" {low} ":
                return "claude"
            stack.append(pid)
    return None


def for_pane(pane_or_cwd: str) -> AgentSource:
    """Pick the right adapter for a pane id (%N) or a raw cwd. Chooses by the
    REPL actually running in the pane; only falls back to transcript-existence
    when that can't be determined (e.g. a raw cwd with no pane)."""
    if pane_or_cwd.startswith("%"):
        cwd = _tmux(pane_or_cwd, "#{pane_current_path}")
        repl = _repl_in_pane(pane_or_cwd)
    else:
        cwd = pane_or_cwd
        repl = None
    cc = ClaudeCodeSource(cwd)
    cx = CodexSource(cwd)
    # Authoritative: match the source to the running REPL, even if the OTHER
    # framework left a stale transcript folder in this worktree.
    if repl == "codex" and cx.locate():
        return cx
    if repl == "claude" and cc.locate():
        return cc
    # Inconclusive REPL (raw cwd, or detection failed): fall back to whichever
    # transcript exists, Claude first (its cwd-keyed lookup is exact).
    if cc.locate():
        return cc
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
