---
name: para-voice-script
description: Write a short spoken-word briefing of what you just did to para-llm's voice player so the user can play it back with Ctrl+b p without any re-summarization. Use when the user asks to "say that", "voice this", "read it back", "make a voice script", or wants to hear a spoken summary of the latest work.
---

# para-voice-script

para-llm has a tmux voice layer: pressing `Ctrl+b p` speaks the latest pane
output. Normally it captures the terminal and runs a separate LLM to summarize
it. You already have full context of what you just did, so instead **write the
spoken briefing yourself** and hand it to the player — it plays your text
directly, skipping capture and summarization (faster, cheaper, more accurate).

## How

Pipe a speakable briefing of your latest substantive work to the recorder:

```bash
__VOICE_SCRIPT_PATH__ <<'VOICE'
<your speakable prose here>
VOICE
```

The recorder resolves the current tmux pane automatically (via `$TMUX_PANE`) and
stores the script for that pane. Confirm to the user that it's ready to play
with `Ctrl+b p`.

To remove a script and revert to live capture: `__VOICE_SCRIPT_PATH__ --clear`.
To inspect the current one: `__VOICE_SCRIPT_PATH__ --show`.

## What makes a good voice script

- Speakable prose only — this is read aloud by text-to-speech.
- Summarize the most recent substantive work or result; do not read code,
  diffs, JSON, stack traces, tables, or logs verbatim.
- For a code/diff change, say the intent, the approach, the likely behavior
  impact, and any notable risks or follow-up — not the syntax.
- Mention file names, command names, errors, and next actions when they matter.
- Be comprehensive about decisions, results, risks, and next steps, but concise
  in phrasing. Prefer a clear narrative over bullet lists.
- No markdown, headings, or emoji — just sentences.
