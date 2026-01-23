#!/bin/bash
# env-restore.sh - Symlink env files from central store into a clone directory
# Usage: env-restore.sh <project-name> <clone-dir>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/para-llm-config.sh"

PROJECT_NAME="$1"
CLONE_DIR="$2"

if [[ -z "$PROJECT_NAME" || -z "$CLONE_DIR" ]]; then
    exit 0
fi

ENV_STORE="$PARA_LLM_ROOT/.env_files/$PROJECT_NAME"

# Exit silently if no env files exist for this project
if [[ ! -d "$ENV_STORE" ]]; then
    exit 0
fi

# Walk the store and create symlinks
while IFS= read -r -d '' file; do
    # Compute relative path within the store
    rel_path="${file#$ENV_STORE/}"

    target="$CLONE_DIR/$rel_path"

    # Skip existing real files (not symlinks) to avoid overwriting manual placements
    if [[ -f "$target" && ! -L "$target" ]]; then
        continue
    fi

    # Create parent directories if needed
    mkdir -p "$(dirname "$target")"

    # Create symlink (force to update existing symlinks)
    ln -sf "$file" "$target"
done < <(find "$ENV_STORE" -type f -print0)
