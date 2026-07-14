#!/usr/bin/env bash
# stream-rewrite.sh - speak mode's "make it listenable" phase.
# Sits between the watcher (raw/ queue: settled transcript text) and the synth
# (chunks/ queue: speakable text). Consumes ALL pending raw items as one batch,
# rewrites them into natural spoken narration via codex (the only sanctioned
# LLM backend, see ADR-009), and enqueues the result. Batching is self-pacing:
# while one rewrite runs, more raw text accumulates and rides the next batch,
# so the backlog is bounded at roughly one rewrite-call of latency (~5-20s).
# If codex is unavailable or a call fails/times out, the batch passes through
# with heuristic cleanup instead — the stream degrades, never stalls.
#
# Usage: stream-rewrite.sh <pane_id> <spool_dir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANE_ID="${1:?usage: stream-rewrite.sh <pane_id> <spool_dir>}"
SPOOL="${2:?usage: stream-rewrite.sh <pane_id> <spool_dir>}"

TTS_DIR="/tmp/para-llm-tts"
STREAM_PANE_FILE="$TTS_DIR/stream.pane"
SAFE_PANE_ID="${PANE_ID#%}"

BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
fi

TTS_SYNTH_CHARS="${TTS_SYNTH_CHARS:-180}"
TTS_STREAM_REWRITE_TIMEOUT="${TTS_STREAM_REWRITE_TIMEOUT:-45}"

source "$SCRIPT_DIR/tts-lib.sh"

RAW="$SPOOL/raw"
CHUNKS="$SPOOL/chunks"
ERROR_LOG="$SPOOL/error.log"

log_error() {
    printf '%s  rewrite: %s\n' "$(date '+%H:%M:%S')" "$*" >> "$ERROR_LOG" 2>/dev/null || true
}

mode_active() {
    [[ "$(cat "$STREAM_PANE_FILE" 2>/dev/null)" == "$SAFE_PANE_ID" ]]
}

run_capped() {
    if [[ -n "$TIMEOUT_CMD" && "$TTS_STREAM_REWRITE_TIMEOUT" != "0" ]]; then
        "$TIMEOUT_CMD" -k 5 "$TTS_STREAM_REWRITE_TIMEOUT" "$@"
    else
        "$@"
    fi
}

# Rewrite $1 (raw text file) into $2 (speakable narration). Non-zero on any
# failure; caller falls back to pass-through.
rewrite_batch() {
    local in="$1" out="$2"
    command -v codex >/dev/null 2>&1 || return 1
    local prompt="$SPOOL/rewrite.prompt"
    cat > "$prompt" <<'PROMPT_EOF'
Rewrite the captured coding-agent output below as natural spoken narration for text-to-speech.

Rules:
- Speakable prose only: no markdown, bullets, symbols, or formatting.
- This is a rewrite, not a summary — keep every substantive point, in order.
- Compress technical noise into natural references: say file and script names without paths or extensions ("the stream watcher script"), skip hashes, flags, and line numbers unless they matter.
- For code fragments, diffs, or commands, say what they do in one short phrase instead of reading them.
- Numbers and error messages that matter should be spoken plainly.
- If the text is already conversational, pass it through nearly unchanged.
- Output only the narration, nothing else.

Captured output:
PROMPT_EOF
    cat "$in" >> "$prompt"
    run_capped codex exec --skip-git-repo-check --sandbox read-only \
        --output-last-message "$out" - < "$prompt" >/dev/null 2>>"$ERROR_LOG"
    local status=$?
    rm -f "$prompt"
    [[ "$status" -eq 0 && -s "$out" ]]
}

# Heuristic fallback: the pre-rewrite behavior (normalize already ran in
# stream-step), just pass the text along.
enqueue_text() {
    local file="$1"
    local chunk_dir="$SPOOL/rewrite.chunks"
    split_speech_for_synthesis "$file" "$chunk_dir" "$TTS_SYNTH_CHARS" || return 1
    local next chunk final count=0
    next="$(cat "$CHUNKS/.next" 2>/dev/null || echo 1)"
    for chunk in "$chunk_dir"/chunk-*.txt; do
        [[ -f "$chunk" ]] || continue
        final="$CHUNKS/$(printf '%05d' "$next").txt"
        mv "$chunk" "$final"
        next=$((next + 1))
        count=$((count + 1))
    done
    echo "$next" > "$CHUNKS/.next"
    rm -rf "$chunk_dir"
    return 0
}

# Wait for the mode file like the other workers (see toggle-stream start order).
tries=0
until mode_active; do
    tries=$((tries + 1))
    [[ "$tries" -gt 20 ]] && exit 0
    sleep 0.1
done

mkdir -p "$RAW"
batch="$SPOOL/rewrite.batch"
spoken="$SPOOL/rewrite.out"

while mode_active; do
    # The recap owns the chunk queue while framing.lock exists.
    if [[ -f "$SPOOL/framing.lock" ]]; then
        sleep 0.3
        continue
    fi

    raw_files=("$RAW"/*.txt)
    if [[ ! -f "${raw_files[0]:-}" ]]; then
        sleep 0.3
        continue
    fi

    : > "$batch"
    consumed=()
    for f in "${raw_files[@]}"; do
        [[ -f "$f" ]] || continue
        cat "$f" >> "$batch"
        printf '\n' >> "$batch"
        consumed+=("$f")
    done

    if rewrite_batch "$batch" "$spoken"; then
        enqueue_text "$spoken" || log_error "failed to enqueue rewritten batch"
    else
        log_error "codex rewrite failed; passing batch through raw"
        enqueue_text "$batch" || log_error "failed to enqueue raw fallback"
    fi
    rm -f "${consumed[@]}" "$spoken"
done
