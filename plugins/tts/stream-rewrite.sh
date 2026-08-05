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
# 20s, not 45: narration lagging 45s behind the pane is worse than raw text
# spoken promptly (user-reported "horribly slow", 2026-07-19).
TTS_STREAM_REWRITE_TIMEOUT="${TTS_STREAM_REWRITE_TIMEOUT:-20}"
# Batches below this size with no technical residue skip codex entirely —
# the call overhead (5-30s) dwarfs any listenability gain on plain prose.
TTS_STREAM_REWRITE_MIN_CHARS="${TTS_STREAM_REWRITE_MIN_CHARS:-220}"
# After a codex failure/timeout, pass batches through raw for this long
# instead of stalling every batch on a degraded backend.
TTS_STREAM_REWRITE_COOLDOWN="${TTS_STREAM_REWRITE_COOLDOWN:-120}"

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

# Strip a leading LLM preamble ("Here's the narration:", "Sure! …") and any
# leading blank lines — claude -p sometimes prefaces, and that must never be
# spoken.
strip_preamble() {
    perl -0pi -e 's/\A\s*(?:sure[,!.]?\s*)?(?:here(?:\x27s| is)?\b[^\n:]{0,40}:|narration:)\s*\n+//i; s/\A\s+//' "$1" 2>/dev/null || true
}

# Rewrite $1 (raw text file) into $2 (speakable narration). Non-zero on any
# failure; caller falls back to pass-through.
# Backend: claude by default (Sonnet). The OpenAI codex sub was cancelled
# 2026-07; codex is retained as an option — TTS_STREAM_REWRITE_BACKEND=codex,
# TTS_STREAM_REWRITE_MODEL=haiku|sonnet.
rewrite_batch() {
    local in="$1" out="$2"
    local backend="${TTS_STREAM_REWRITE_BACKEND:-claude}"
    local model="${TTS_STREAM_REWRITE_MODEL:-sonnet}"
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
- Output ONLY the narration. No preamble, no "Here is", no closing remark — just the spoken text.

Captured output:
PROMPT_EOF
    cat "$in" >> "$prompt"
    local status
    case "$backend" in
        claude)
            command -v claude >/dev/null 2>&1 || { rm -f "$prompt"; return 1; }
            run_capped claude -p --model "$model" < "$prompt" > "$out" 2>>"$ERROR_LOG"
            status=$?
            ;;
        codex)
            command -v codex >/dev/null 2>&1 || { rm -f "$prompt"; return 1; }
            run_capped codex exec --skip-git-repo-check --sandbox read-only \
                --output-last-message "$out" - < "$prompt" >/dev/null 2>>"$ERROR_LOG"
            status=$?
            ;;
        *) rm -f "$prompt"; return 1 ;;
    esac
    rm -f "$prompt"
    [[ "$status" -eq 0 && -s "$out" ]] || return 1
    strip_preamble "$out"
    [[ -s "$out" ]]
}

# True when the batch is worth a codex pass: big enough, or carrying
# technical residue (paths, code punctuation, long tokens like hashes) that
# reads badly as speech. Plain short prose goes straight through.
batch_needs_rewrite() {
    local file="$1" chars
    chars="$(wc -c < "$file" | tr -d ' ')"
    if (( chars >= TTS_STREAM_REWRITE_MIN_CHARS )); then return 0; fi
    grep -qE '[/\\`_{}<>=#]|[[:alnum:]]{18,}' "$file"
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
last_fail=0

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

    now="$(date +%s)"
    if (( now - last_fail < TTS_STREAM_REWRITE_COOLDOWN )); then
        # Circuit breaker: a degraded codex must not tax every batch.
        enqueue_text "$batch" || log_error "failed to enqueue raw (cooldown)"
    elif ! batch_needs_rewrite "$batch"; then
        enqueue_text "$batch" || log_error "failed to enqueue raw (plain prose)"
    elif rewrite_batch "$batch" "$spoken"; then
        enqueue_text "$spoken" || log_error "failed to enqueue rewritten batch"
    else
        last_fail="$(date +%s)"
        log_error "codex rewrite failed; raw pass-through for ${TTS_STREAM_REWRITE_COOLDOWN}s"
        enqueue_text "$batch" || log_error "failed to enqueue raw fallback"
    fi
    rm -f "${consumed[@]}" "$spoken"
done
