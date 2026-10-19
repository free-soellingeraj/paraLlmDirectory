#!/usr/bin/env python3
"""Extract the editable REPL input from a plain tmux pane capture.

Claude Code places its composer between two heavy horizontal rules. Codex uses
the last ``›`` prompt followed by wrapped two-space-indented lines and then a
blank/status footer. Keeping both grammars here lets voice ``send`` verify the
REPL that is actually in the pane instead of assuming Claude's screen shape.
"""
from __future__ import annotations

import re
import sys


_CLAUDE_RULE = re.compile(r"^\s*[─═━▔]{20,}\s*$")
_CODEX_PROMPT = re.compile(r"^\s*›\s?(.*)$")
_CODEX_PLACEHOLDER = re.compile(r"^Ask Codex to do anything\s*$", re.I)


def _one_line(lines: list[str]) -> str:
    return " ".join(" ".join(lines).split()).strip()


def extract_input_region(capture: str) -> str:
    lines = capture.replace("\r", "").splitlines()

    # Codex: select the LAST prompt so old user turns still visible in history
    # cannot be mistaken for what is currently editable at the bottom.
    prompts = [(i, m.group(1)) for i, line in enumerate(lines)
               if (m := _CODEX_PROMPT.match(line))]
    if prompts:
        start, first = prompts[-1]
        block = [first]
        for line in lines[start + 1:]:
            if not line.strip():
                break
            block.append(line.strip())
        text = _one_line(block)
        return "" if _CODEX_PLACEHOLDER.match(text) else text

    # Claude Code: the final two rules surround the editable composer. Its first
    # line starts with ❯ and wrapped lines are unmarked.
    rules = [i for i, line in enumerate(lines) if _CLAUDE_RULE.match(line)]
    if len(rules) >= 2:
        block = lines[rules[-2] + 1:rules[-1]]
        if block:
            block[0] = re.sub(r"^\s*❯\s?", "", block[0])
        return _one_line(block)
    return ""


if __name__ == "__main__":
    print(extract_input_region(sys.stdin.read()))
