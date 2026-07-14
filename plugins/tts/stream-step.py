#!/usr/bin/env python3
"""One speak-mode poll step: diff the pane transcript, collect settled text,
emit sentence chunks for synthesis.

Called by stream-watcher.sh once per poll with the spool dir as argv[1].
State lives in files so each step is a fresh process:

  cur.txt       filtered transcript captured this poll (input, written by watcher)
  prev.txt      filtered transcript from the previous poll
  spoken.count  number of transcript lines already handed to the synth queue
  pending.txt   settled text waiting for a sentence boundary
  chunks/NNN.txt      emitted chunks, consumed in order by stream-synth.sh
  chunks/.next        next chunk sequence number

A transcript line is "settled" once it is identical across two consecutive
polls — that excludes the TUI's mutating tail (spinner, input box, the
paragraph still being streamed) without needing to understand the TUI.
"""

import os
import re
import sys
import time

spool = sys.argv[1]
max_chars = max(80, int(os.environ.get("TTS_SYNTH_CHARS", "180") or "180"))
flush_secs = float(os.environ.get("TTS_STREAM_FLUSH_SECS", "4") or "4")

cur_path = os.path.join(spool, "cur.txt")
prev_path = os.path.join(spool, "prev.txt")
spoken_path = os.path.join(spool, "spoken.count")
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


cur = read_lines(cur_path) or []
prev = read_lines(prev_path)

if prev is None:
    # First poll: anchor to the current transcript so we only ever speak text
    # that arrives after speak mode was enabled.
    write_text(prev_path, "\n".join(cur))
    write_text(spoken_path, str(len(cur)))
    log_event("anchored at line %d" % len(cur))
    sys.exit(0)

try:
    spoken = int(read_text(spoken_path).strip() or "0")
except ValueError:
    spoken = len(cur)

# Longest common prefix (in lines) of the two captures. Everything below it is
# stable scrollback; everything at/after it changed this poll and must wait.
settled = 0
limit = min(len(prev), len(cur))
while settled < limit and prev[settled] == cur[settled]:
    settled += 1

# Lines we speak vs. skip. The shared chrome filter already ran; these are the
# streaming-specific drops: tool invocations/results, echoed user input,
# spinner/status glyphs, deep-indented continuation output.
DROP_PATTERNS = [
    re.compile(r"^\s*⎿"),                # tool result marker
    re.compile(r"^\s{4,}"),              # tool output continuation / code indent
    re.compile(r"^\s*>\s"),              # echoed user prompt
    re.compile(r"^\s*[✻✽✶✳✢∴☐☒⚒]"),      # spinner / todo / status glyphs
    re.compile(r"^⏺\s+\w[\w-]*\("),      # tool call lines like "⏺ Bash(ls)"
    re.compile(r"\?\s+for shortcuts"),
    re.compile(r"[Bb]ypassing [Pp]ermissions"),
    re.compile(r"^\s*[-+═─—]{3,}\s*$"),  # rules / separators
]


def speakable(line):
    return not any(p.search(line) for p in DROP_PATTERNS)


old_pending = read_text(pending_path)
pending = old_pending
grew = False

# The last line or two of a transcript mutate in place (the paragraph still
# being streamed, a shell prompt gaining typed text). A small dip of the
# common prefix below the anchor is that tail churn — un-anchor those lines so
# their final form is spoken once it settles. Only a large divergence means
# the screen was really rewritten (clear, screen switch, scrollback trim).
TAIL_WINDOW = 3

if settled < spoken:
    if spoken - settled <= TAIL_WINDOW:
        spoken = settled
    else:
        # Re-anchor to what's visible now instead of re-speaking history.
        log_event("resync: settled=%d < spoken=%d; re-anchoring at %d"
                  % (settled, spoken, len(cur)))
        spoken = len(cur)
else:
    fresh = [l for l in cur[spoken:settled] if speakable(l)]
    block = "\n".join(fresh).strip()
    if block:
        pending = (pending.rstrip() + "\n" + block) if pending.strip() else block
        grew = True
    spoken = settled if settled > spoken else spoken

write_text(prev_path, "\n".join(cur))
write_text(spoken_path, str(spoken))


def normalize(text):
    text = text.replace("⏺", " ").replace("●", " ").replace("•", " ")
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
