#!/usr/bin/env bash
# summarize-for-speech.sh - turn raw terminal text into concise speakable prose.

set -uo pipefail

BACKEND="${1:-auto}"
INPUT_FILE="${2:?Usage: summarize-for-speech.sh <backend> <input-file> <output-file> [cwd]}"
OUTPUT_FILE="${3:?Usage: summarize-for-speech.sh <backend> <input-file> <output-file> [cwd]}"
CWD="${4:-$(pwd)}"

# Hard cap on the summarizer LLM call so a hung/slow backend can't keep the
# "preparing" beep looping forever. 0 disables the cap.
TTS_SUMMARIZE_TIMEOUT="${TTS_SUMMARIZE_TIMEOUT:-60}"

if [[ ! -s "$INPUT_FILE" ]]; then
    exit 1
fi

# Resolve a `timeout`-style command (GNU coreutils on macOS installs it as
# `gtimeout`). Empty if neither is available, in which case we run uncapped.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi

# Run a command with the summarizer timeout if one is configured and available.
# `-k` sends SIGKILL a few seconds after SIGTERM in case the backend ignores it.
run_capped() {
    if [[ -n "$TIMEOUT_CMD" && "$TTS_SUMMARIZE_TIMEOUT" != "0" ]]; then
        "$TIMEOUT_CMD" -k 5 "$TTS_SUMMARIZE_TIMEOUT" "$@"
    else
        "$@"
    fi
}

PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/para-llm-tts-summary.XXXXXX")"
trap 'rm -f "$PROMPT_FILE"' EXIT

cat > "$PROMPT_FILE" <<'PROMPT_EOF'
Prepare this terminal/chat text for text-to-speech as a smart spoken briefing.

Rules:
- Return only speakable prose.
- Begin with ONE short sentence restating what the user most recently asked, e.g. "You asked to fix the login test." Then summarize the response that followed. (This is the one exception to the ignore-user-input rule below.)
- First identify recent turn boundaries: human/user turns and assistant/model turns.
- Treat the latest human/user turn as an endpoint. The target to speak is the assistant/model response that follows that human turn.
- If multiple assistant/model turns appear after the latest human turn, speak the most recent substantive one.
- If the capture ends with a new human input, unfinished prompt, or command line and there is no assistant/model response after it, look back to the previous completed assistant/model turn.
- Ignore user input, shell prompts, command prompts, trust dialogs, menus, status bars, keybinding hints, progress indicators, and unfinished input boxes.
- If the latest visible lines are only terminal UI or an input prompt, look earlier for the most recent substantive assistant/model response.
- If there is no assistant/model response, summarize the latest substantive terminal command result.
- Preserve the important meaning of that latest response or result.
- Do not read code, diffs, stack traces, JSON, tables, or logs verbatim.
- For diffs, summarize the intent of the change, the implementation approach, the likely behavior impact, and any notable risks or follow-up work.
- For large code/text blocks, explain what changed, what failed, or what matters rather than reading structure or syntax.
- Mention file names, command names, errors, and next actions when they are important.
- Be comprehensive about decisions, results, risks, and next steps.
- Be concise in phrasing, but do not make it artificially short.
- Prefer a clear narrative over bullets unless bullets are the most speakable format.

Terminal text:
PROMPT_EOF
cat "$INPUT_FILE" >> "$PROMPT_FILE"

run_codex() {
    command -v codex >/dev/null 2>&1 || return 1
    (cd "$CWD" && run_capped codex exec --skip-git-repo-check --sandbox read-only --output-last-message "$OUTPUT_FILE" - < "$PROMPT_FILE") >/dev/null
}

run_claude() {
    command -v claude >/dev/null 2>&1 || return 1
    (cd "$CWD" && run_capped claude -p --model "${TTS_SUMMARIZER_MODEL:-sonnet}" < "$PROMPT_FILE" > "$OUTPUT_FILE")
}

# Backend: claude by default. The OpenAI codex sub was cancelled 2026-07, so
# ADR-009's "codex only, claude -p retired for metered billing" is superseded —
# claude is the path now; codex is kept as a fallback/option. `claude -p` can
# preface its output, so strip a leading preamble after a successful run.
case "$BACKEND" in
    claude) run_claude ;;
    codex)  run_codex ;;
    auto|*) run_claude || run_codex ;;
esac
status=$?
if [[ "$status" -eq 0 && -s "$OUTPUT_FILE" ]]; then
    perl -0pi -e 's/\A\s*(?:sure[,!.]?\s*)?(?:here(?:\x27s| is)?\b[^\n:]{0,40}:|summary:|narration:)\s*\n+//i; s/\A\s+//' "$OUTPUT_FILE" 2>/dev/null || true
fi

# A timeout or backend error may leave a truncated/partial summary behind;
# discard it so the caller falls back to the raw pane text instead of speaking
# a half-finished sentence.
if [[ "$status" -ne 0 ]]; then
    rm -f "$OUTPUT_FILE"
    exit 1
fi

[[ -s "$OUTPUT_FILE" ]]
