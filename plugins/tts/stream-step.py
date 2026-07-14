#!/usr/bin/env python3
"""One speak-mode poll step: diff the pane transcript, collect settled text,
emit sentence chunks for synthesis.

Called by stream-watcher.sh once per poll with the spool dir as argv[1].
State lives in files so each step is a fresh process:

  cur.txt      filtered transcript captured this poll (input, written by watcher)
  prev.txt     speakable lines from the previous poll
  anchor.txt   the last few lines already consumed (content, not indices)
  pending.txt  settled text waiting for a sentence boundary
  chunks/NNNNN.txt   emitted chunks, consumed in order by stream-synth.sh
  chunks/.next       next chunk sequence number

Anchoring is by CONTENT, not line index: Claude Code (and other TUIs) run on
the alternate screen, where the capture is just the viewport and every line
shifts up as output scrolls. We find the last occurrence of the anchor block
in the new capture; whatever follows it is candidate text. A candidate line is
"settled" (safe to speak) once it appears identically in two consecutive polls
— that excludes the still-streaming tail without understanding the TUI.
"""

import os
import re
import sys
import time

spool = sys.argv[1]
max_chars = max(80, int(os.environ.get("TTS_SYNTH_CHARS", "180") or "180"))
flush_secs = float(os.environ.get("TTS_STREAM_FLUSH_SECS", "4") or "4")

ANCHOR_LINES = 8

cur_path = os.path.join(spool, "cur.txt")
prev_path = os.path.join(spool, "prev.txt")
anchor_path = os.path.join(spool, "anchor.txt")
pending_path = os.path.join(spool, "pending.txt")
chunks_dir = os.path.join(spool, "chunks")
next_path = os.path.join(chunks_dir, ".next")
events_path = os.path.join(spool, "events.log")


def read_lines(path):
    try:
        with open(path, errors="replace") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return None


def read_text(path, default=""):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return default


def write_text(path, text):
    with open(path, "w") as f:
        f.write(text)


def log_event(msg):
    with open(events_path, "a") as f:
        f.write("%s  %s\n" % (time.strftime("%H:%M:%S"), msg))


# Lines that must never reach the diff: anything that churns while the agent
# works (spinners, timers, token counters, prompt, separators) would otherwise
# destabilize settling, and tool chatter isn't speech. The shared chrome
# filter (filter-pane-text.sh) already ran in the watcher; these are the
# streaming-specific drops, applied BEFORE anchoring so cur/prev only ever
# contain speakable transcript lines.
DROP_PATTERNS = [
    re.compile(r"^\s*⎿"),                    # tool result marker
    re.compile(r"^\s{4,}"),                  # tool output continuation / code indent
    re.compile(r"^\s*[>❯›]\s?"),             # prompt line / echoed user input
    re.compile(r"^\s*[✻✽✶✳✢∴☐☒⚒·•▸▪⏵]"),     # spinner / status / todo glyphs
    re.compile(r"^⏺\s+\w[\w-]*\("),          # finalized tool line: "⏺ Bash(ls)"
    re.compile(r"…\s*(\(\d[^)]*\))?\s*$"),   # in-progress ellipsis, optional timer: "Running 1 shell command… (3s)"
    re.compile(r"^\s*Running \d+ shell command"),  # tool header renders with 2-space indent, no ⏺
    re.compile(r"^\s*[─═━┄┈╌\-_=]{4,}\s*$"), # separators / rules
    re.compile(r"\?\s+for shortcuts"),
    re.compile(r"[Bb]ypassing [Pp]ermissions"),
    re.compile(r"\(ctrl\+"),                 # inline keyboard hints
    re.compile(r"↓.*tokens|tokens\)"),       # token counters
    re.compile(r"esc to interrupt"),
]


def speakable(line):
    return line.strip() and not any(p.search(line) for p in DROP_PATTERNS)


def find_anchor_end(lines, anchor):
    """(index, block) just past the LAST occurrence of the anchor in lines.

    Tolerates two kinds of drift: the anchor's OLDEST lines scrolling out of
    the viewport (match progressively shorter suffixes), and its NEWEST lines
    mutating after they were anchored — the first-poll anchor grabs whatever
    is on screen, including a paragraph still streaming (trim newest first,
    so enabling mid-response recovers instead of resyncing forever). Returns
    the block that actually matched so the caller can rebuild the anchor
    without the stale lines. (None, None) means a real rewrite or flood.
    """
    for trim_new in range(len(anchor)):
        base = anchor[:len(anchor) - trim_new]
        for start in range(len(base)):
            block = base[start:]
            for i in range(len(lines) - len(block), -1, -1):
                if lines[i:i + len(block)] == block:
                    return i + len(block), block
    return None, None


cur = read_lines(cur_path) or []
spk_cur = [l for l in cur if speakable(l)]
spk_prev = read_lines(prev_path)
anchor = read_lines(anchor_path) or []

if spk_prev is None:
    # First poll: anchor to what's on screen so we only speak what comes next.
    write_text(prev_path, "\n".join(spk_cur))
    write_text(anchor_path, "\n".join(spk_cur[-ANCHOR_LINES:]))
    log_event("anchored on %d speakable lines" % len(spk_cur))
    sys.exit(0)

old_pending = read_text(pending_path)
pending = old_pending
grew = False

if anchor:
    i_cur, matched = find_anchor_end(spk_cur, anchor)
    i_prev, _ = find_anchor_end(spk_prev, anchor)
else:
    # Empty anchor (pane was empty at enable): everything is candidate text.
    i_cur, i_prev, matched = 0, 0, []

if i_cur is None:
    # Anchor vanished: pane cleared, screen switched, or output flooded past
    # the viewport between polls. Re-anchor to now rather than re-speak or
    # guess; the skipped text is logged.
    log_event("resync: anchor lost; re-anchoring on %d lines" % len(spk_cur))
    anchor = spk_cur[-ANCHOR_LINES:]
else:
    new_cur = spk_cur[i_cur:]
    new_prev = spk_prev[i_prev:] if i_prev is not None else []
    settled = []
    for a, b in zip(new_prev, new_cur):
        if a != b:
            break
        settled.append(a)
    # Rebuild the anchor from the block that matched — keeping trimmed-away
    # stale lines would leave a block that can never match again.
    if settled:
        block = "\n".join(settled).strip()
        if block:
            pending = (pending.rstrip() + "\n" + block) if pending.strip() else block
            grew = True
        anchor = (matched + settled)[-ANCHOR_LINES:]
    elif matched != anchor:
        anchor = matched

write_text(prev_path, "\n".join(spk_cur))
write_text(anchor_path, "\n".join(anchor))


def normalize(text):
    text = text.replace("⏺", " ").replace("●", " ")
    text = re.sub(r"[*_`#|]+", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


text = normalize(pending)
if not text:
    if old_pending:
        write_text(pending_path, "")
    sys.exit(0)

# Split into sentences; whole sentences go to the synth queue now, the
# trailing fragment waits for its ending — unless it has been sitting quiet
# for flush_secs (headers and bullets often lack terminal punctuation).
parts = re.split(r"(?<=[.!?:;])\s+", text)
if re.search(r"[.!?:;]$", parts[-1]):
    complete, remainder = parts, ""
else:
    complete, remainder = parts[:-1], parts[-1]

if remainder and not grew and os.path.exists(pending_path):
    age = time.time() - os.path.getmtime(pending_path)
    if age >= flush_secs:
        complete = complete + [remainder]
        remainder = ""

chunks = []
buf = ""
for sentence in complete:
    sentence = sentence.strip()
    if not sentence:
        continue
    if len(buf) + len(sentence) + 1 <= max_chars:
        buf = (buf + " " + sentence).strip()
        continue
    if buf:
        chunks.append(buf)
    while len(sentence) > max_chars:
        cut = sentence.rfind(" ", 0, max_chars)
        cut = cut if cut > 0 else max_chars
        chunks.append(sentence[:cut].strip())
        sentence = sentence[cut:].strip()
    buf = sentence
if buf:
    chunks.append(buf)

if chunks:
    os.makedirs(chunks_dir, exist_ok=True)
    try:
        nxt = int(read_text(next_path).strip() or "1")
    except ValueError:
        nxt = 1
    for chunk in chunks:
        final = os.path.join(chunks_dir, "%05d.txt" % nxt)
        part = final + ".part"
        write_text(part, chunk + "\n")
        os.replace(part, final)  # synth worker only ever sees complete files
        nxt += 1
    write_text(next_path, str(nxt))

# Only rewrite pending when its content changed — the stale-flush timer above
# reads this file's mtime, so an idle rewrite would reset the clock.
if remainder != old_pending:
    write_text(pending_path, remainder)
