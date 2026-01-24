#!/usr/bin/env bash

set -u

# envs - Show status of all parallel development environments
# Usage: envs [options]
#   -v, --verbose  Show more details (last commit, etc.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
source "$SCRIPT_DIR/para-llm-config.sh"

VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; shift ;;
        *) shift ;;
    esac
done

if [[ ! -d "$ENVS_DIR" ]]; then
    echo "No envs directory at $ENVS_DIR"
    exit 1
fi

# Header
printf "%-40s %-25s %s\n" "ENVIRONMENT" "BRANCH" "STATUS"
printf "%-40s %-25s %s\n" "-----------" "------" "------"

for d in "$ENVS_DIR"/*/; do
    [[ ! -d "$d" ]] && continue

    env_name=$(basename "$d")

    # Find the git repo inside the env directory
    repo=$(find "$d" -maxdepth 2 -name ".git" -type d 2>/dev/null | head -1)

    if [[ -z "$repo" ]]; then
        printf "%-40s %-25s %s\n" "$env_name" "(no git)" "-"
        continue
    fi

    dir=$(dirname "$repo")
    branch=$(git -C "$dir" branch --show-current 2>/dev/null)

    # Count changes
    staged=$(git -C "$dir" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    unstaged=$(git -C "$dir" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    untracked=$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

    # Check for unpushed commits
    unpushed=$(git -C "$dir" log --oneline @{u}.. 2>/dev/null | wc -l | tr -d ' ')

    # Build status string
    status=""
    [[ "$staged" -gt 0 ]] && status+="${staged} staged "
    [[ "$unstaged" -gt 0 ]] && status+="${unstaged} modified "
    [[ "$untracked" -gt 0 ]] && status+="${untracked} untracked "
    [[ "$unpushed" -gt 0 ]] && status+="↑${unpushed} unpushed "
    [[ -z "$status" ]] && status="clean"

    printf "%-40s %-25s %s\n" "$env_name" "$branch" "$status"

    if $VERBOSE && [[ "$unpushed" -gt 0 ]]; then
        git -C "$dir" log --oneline @{u}.. 2>/dev/null | sed 's/^/    /'
    fi
done
