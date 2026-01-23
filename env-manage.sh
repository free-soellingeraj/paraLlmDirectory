#!/bin/bash
# env-manage.sh - Interactive manager for centrally stored .env files
# Bound to Ctrl+b e via tmux display-popup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/para-llm-config.sh"

ENV_STORE="$PARA_LLM_ROOT/.env_files"
mkdir -p "$ENV_STORE"

# Select action
action_add() {
    # Find .env files across all projects in CODE_DIR (skip heavy dirs)
    local env_file
    env_file=$(find "$CODE_DIR" \
        \( -name node_modules -o -name .git -o -name ".para-llm-directory" \) -prune -o \
        -name ".env*" -type f -print 2>/dev/null | \
        sed "s|^$CODE_DIR/||" | \
        sort | \
        fzf --prompt="Select .env file to add: " --height=80% --reverse)

    if [[ -z "$env_file" ]]; then
        return
    fi

    local full_path="$CODE_DIR/$env_file"

    # Determine the project name (first path component)
    local project
    project=$(echo "$env_file" | cut -d'/' -f1)

    # Show detected project, allow override
    local projects
    projects=$(find "$CODE_DIR" -maxdepth 2 -name ".git" -type d -not -path "*/.para-llm-directory/*" 2>/dev/null | \
        xargs -I {} dirname {} | \
        sed "s|${CODE_DIR}/||" | \
        grep -v '/' | \
        sort -u)

    local selected_project
    selected_project=$(echo "$projects" | \
        fzf --prompt="Associate with project (detected: $project): " \
            --height=40% --reverse \
            --query="$project")

    if [[ -z "$selected_project" ]]; then
        return
    fi

    # Compute the relative path within the project
    local rel_path
    rel_path=$(echo "$env_file" | sed "s|^$selected_project/||")

    # Create destination directory and copy
    local dest="$ENV_STORE/$selected_project/$rel_path"
    mkdir -p "$(dirname "$dest")"
    cp "$full_path" "$dest"
    chmod 600 "$dest"

    echo ""
    echo "Added: $selected_project/$rel_path"
    echo "Stored at: $dest"

    # Auto-update existing clones for this project
    echo ""
    echo "Updating existing clones..."
    for env_dir in "$ENVS_DIR"/${selected_project}-*/; do
        if [[ -d "$env_dir" ]]; then
            local clone_dir="${env_dir}${selected_project}"
            if [[ -d "$clone_dir" ]]; then
                "$SCRIPT_DIR/env-restore.sh" "$selected_project" "$clone_dir"
                echo "  Updated: $(basename "$env_dir")"
            fi
        fi
    done

    echo ""
    echo "Done. Press enter to close."
    read -r
}

action_list() {
    echo "=== Managed .env Files ==="
    echo ""

    local found=0
    for project_dir in "$ENV_STORE"/*/; do
        if [[ -d "$project_dir" ]]; then
            local project
            project=$(basename "$project_dir")
            echo "[$project]"
            while IFS= read -r -d '' file; do
                local rel="${file#$project_dir}"
                echo "  $rel"
                found=1
            done < <(find "$project_dir" -type f -print0 | sort -z)
            echo ""
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "(No env files managed yet)"
        echo ""
        echo "Use 'Add' to register .env files from your projects."
    fi

    echo ""
    echo "Press enter to close."
    read -r
}

action_remove() {
    # Collect all managed files
    local files
    files=$(find "$ENV_STORE" -type f 2>/dev/null | \
        sed "s|^$ENV_STORE/||" | \
        sort)

    if [[ -z "$files" ]]; then
        echo "No managed env files to remove."
        echo "Press enter to close."
        read -r
        return
    fi

    local selected
    selected=$(echo "$files" | \
        fzf --prompt="Select file to remove: " --height=80% --reverse)

    if [[ -z "$selected" ]]; then
        return
    fi

    echo ""
    echo "Remove: $selected"
    echo -n "Are you sure? [y/N]: "
    read -r confirm

    if [[ "$confirm" =~ ^[Yy] ]]; then
        rm -f "$ENV_STORE/$selected"

        # Clean up empty parent directories
        local dir
        dir=$(dirname "$ENV_STORE/$selected")
        while [[ "$dir" != "$ENV_STORE" && -d "$dir" ]]; do
            if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
                rmdir "$dir"
                dir=$(dirname "$dir")
            else
                break
            fi
        done

        echo "Removed: $selected"
    else
        echo "Cancelled."
    fi

    echo ""
    echo "Press enter to close."
    read -r
}

# Main menu
main() {
    local action
    action=$(printf "Add - register a .env file\nList - show managed files\nRemove - delete a managed file" | \
        fzf --prompt="Env file manager: " --height=20% --reverse)

    case "$action" in
        "Add - register a .env file")
            action_add
            ;;
        "List - show managed files")
            action_list
            ;;
        "Remove - delete a managed file")
            action_remove
            ;;
    esac
}

main
