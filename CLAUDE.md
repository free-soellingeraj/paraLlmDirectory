# paraLlmDirectory

<!-- BEGIN LLM-CONTEXT-MANAGED -->
## Documentation System

This project uses a topic-based documentation system for LLM context.

### Structure
- `CLAUDE.md` - This file. Minimal, always loaded. Contains conventions and quick reference.
- `.llm-context/topics/` - Detailed docs accessed via `./ctx <topic>`
- `ctx` - Shell script to list/view topics

### Conventions for Claude

**When implementing features/fixes, update the appropriate topic files:**

| Work Type | Update These Topics |
|-----------|---------------------|
| Bug fix | `bugs-fixed` (add entry with cause/fix/file) |
| Architecture decision | `architectural-decisions` (add ADR-style entry) |
| New feature | `product-features` (document feature and usage) |
| Tech stack change | `tech-stack` (update dependencies/tools) |
| New logging/debugging | `debugging` (add debugging tips) |
| CI/CD change | `cicd` (document pipeline changes) |
| Data model change | `data-model` (update schema docs) |

**When to create a new topic:**
- Major new feature area (e.g., `authentication`, `notifications`)
- New integration (e.g., `analytics`, `push-notifications`)
- Complex subsystem that needs dedicated documentation

**Topic file format:**
```markdown
# Topic Title

## Section
Content with **bold** for emphasis
- Bullet points for lists
- `code` for inline code
- Code blocks for multi-line

**File**: path/to/file.ext:line (when relevant)
```

### Commands
```bash
./ctx              # List available topics
./ctx <topic>      # View topic content
```

### Updating llm-context
To update this project's llm-context tools to the latest version:
1. Read `.llm-context/.source` to get the llm-context install path
2. Run `<path>/llm-context update` in this project directory

This will update the ctx script, merge new deny rules into settings, and refresh the managed section of this file while preserving your customizations.
<!-- END LLM-CONTEXT-MANAGED -->


## Quick Reference

<!-- Add project-specific quick reference here -->
