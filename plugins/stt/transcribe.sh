#!/usr/bin/env bash

# Transcribe a WAV file using whisper.cpp
# Usage: transcribe.sh <wav-file>
# Output: transcribed text on stdout

set -euo pipefail

WAV_FILE="${1:?Usage: transcribe.sh <wav-file>}"

if [[ ! -f "$WAV_FILE" ]]; then
    echo "Error: Audio file not found: $WAV_FILE" >&2
    exit 1
fi

# Load config for optional STT_MODEL_PATH / STT_LANGUAGE
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
    if [[ -f "$PARA_LLM_ROOT/config" ]]; then
        source "$PARA_LLM_ROOT/config"
    fi
fi

LANGUAGE="${STT_LANGUAGE:-en}"

# Find whisper binary (homebrew installs as whisper-cli)
WHISPER_BIN=""
if command -v whisper-cli &>/dev/null; then
    WHISPER_BIN="whisper-cli"
elif command -v whisper-cpp &>/dev/null; then
    WHISPER_BIN="whisper-cpp"
else
    echo "Error: whisper-cli not found. Install whisper-cpp with your package manager (e.g., brew install whisper-cpp / apt install whisper-cpp)" >&2
    exit 1
fi

# Model location
DEFAULT_MODEL="ggml-base.en.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$DEFAULT_MODEL"
MODEL_DIR="${PARA_LLM_ROOT:?PARA_LLM_ROOT not set}/plugins/stt/models"
MODEL_PATH="${STT_MODEL_PATH:-$MODEL_DIR/$DEFAULT_MODEL}"

# Download model if not present
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Downloading whisper model to $MODEL_PATH..." >&2
    mkdir -p "$MODEL_DIR"
    if ! curl -L -o "$MODEL_PATH" "$MODEL_URL" 2>&2; then
        rm -f "$MODEL_PATH"
        echo "Error: Failed to download whisper model" >&2
        exit 1
    fi
    echo "Model downloaded." >&2
fi

# Run transcription
# whisper-cpp outputs to stdout; --no-timestamps gives clean text
OUTPUT=$("$WHISPER_BIN" \
    --model "$MODEL_PATH" \
    --file "$WAV_FILE" \
    --language "$LANGUAGE" \
    --no-timestamps \
    2>/dev/null)

# Clean up: strip leading/trailing whitespace and blank lines
CLEANED=$(echo "$OUTPUT" | sed '/^$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [[ -n "$CLEANED" ]]; then
    echo "$CLEANED"
else
    exit 1
fi
