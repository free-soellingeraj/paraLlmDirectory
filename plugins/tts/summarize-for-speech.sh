#!/usr/bin/env bash
# summarize-for-speech.sh - turn raw terminal text into concise speakable prose.

set -uo pipefail

BACKEND="${1:-auto}"
INPUT_FILE="${2:?Usage: summarize-for-speech.sh <backend> <input-file> <output-file> [cwd]}"
OUTPUT_FILE="${3:?Usage: summarize-for-speech.sh <backend> <input-file> <output-file> [cwd]}"
CWD="${4:-$(pwd)}"

if [[ ! -s "$INPUT_FILE" ]]; then
    exit 1
fi

PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/para-llm-tts-summary.XXXXXX")"
trap 'rm -f "$PROMPT_FILE"' EXIT

cat > "$PROMPT_FILE" <<'PROMPT_EOF'
Prepare this terminal/chat text for text-to-speech as a smart spoken briefing.

Rules:
- Return only speakable prose.
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

run_claude() {
    command -v claude >/dev/null 2>&1 || return 1
    (cd "$CWD" && claude -p --no-session-persistence --output-format text < "$PROMPT_FILE") > "$OUTPUT_FILE"
}

run_codex() {
    command -v codex >/dev/null 2>&1 || return 1
    (cd "$CWD" && codex exec --skip-git-repo-check --sandbox read-only --output-last-message "$OUTPUT_FILE" - < "$PROMPT_FILE") >/dev/null
}

case "$BACKEND" in
    claude)
        run_claude
        ;;
    codex)
        run_codex
        ;;
    auto|*)
        run_codex || run_claude
        ;;
esac

[[ -s "$OUTPUT_FILE" ]]
