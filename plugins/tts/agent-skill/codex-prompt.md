Write a short spoken-word briefing of what you just did and hand it to
para-llm's voice player so the user can play it back with Ctrl+b p.

para-llm has a tmux voice layer: pressing Ctrl+b p speaks the latest pane
output. Normally it captures the terminal and runs a separate LLM to summarize
it. You already have full context, so write the spoken briefing yourself and
record it directly — the player speaks your text as-is, skipping capture and
summarization (faster, cheaper, more accurate).

Record it by piping speakable prose to the recorder (it resolves the current
tmux pane automatically):

    __VOICE_SCRIPT_PATH__ <<'VOICE'
    <your speakable prose here>
    VOICE

To remove it and revert to live capture: __VOICE_SCRIPT_PATH__ --clear
To inspect the current one:            __VOICE_SCRIPT_PATH__ --show

What makes a good voice script:
- Speakable prose only — it is read aloud by text-to-speech.
- Summarize the most recent substantive work or result; do not read code,
  diffs, JSON, stack traces, tables, or logs verbatim.
- For a code/diff change, say the intent, the approach, the likely behavior
  impact, and notable risks or follow-up — not the syntax.
- Mention file names, command names, errors, and next actions when they matter.
- Be comprehensive about decisions, results, risks, and next steps, but concise
  in phrasing. Prefer a clear narrative over bullet lists.
- No markdown, headings, or emoji — just sentences.

After recording, tell the user it's ready to play with Ctrl+b p.
