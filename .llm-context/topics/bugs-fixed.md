# Bugs Fixed

## Overview
Log of bugs encountered and fixed in the para-llm-directory project. Each entry documents the cause, fix, and affected files.

## Entry Template

```markdown
### BUG-XXX: Brief Description
**Date**: YYYY-MM-DD
**Symptom**: What the user observed
**Cause**: Root cause of the issue
**Fix**: How it was resolved
**File**: path/to/file.ext:line
```

---

## Bug Log

### BUG-001: Auto-close cleanup window
**Date**: 2024 (from commit history)
**Symptom**: After cleaning up a feature branch, the tmux popup window remained open
**Cause**: Missing `tmux kill-window` after successful deletion
**Fix**: Added `tmux kill-window` at the end of successful cleanup flow
**File**: `tmux-cleanup-branch.sh:119`

---

## Known Bug-Prone Areas

### Git Remote Detection
The scripts assume all base repos have an `origin` remote configured. If a repo doesn't have a remote, the clone operation will fail.
**File**: `tmux-new-branch.sh:143-151`, `tmux-new-branch.sh:209-216`

### Branch Name Extraction
The cleanup script extracts branch name by taking everything after the first dash (`${ENV_NAME#*-}`). This works for standard patterns but could fail for edge cases.
**File**: `tmux-cleanup-branch.sh:92`

### Unpushed Commits Detection
The `@{u}` reference requires an upstream branch to be set. New branches without an upstream will show errors (suppressed with `2>/dev/null`).
**File**: `tmux-cleanup-branch.sh:74`, `envs.sh:48`

---

## Notes for Future Bug Entries

When fixing bugs, document:
1. How the bug was discovered (user report, testing, etc.)
2. Steps to reproduce
3. The actual vs expected behavior
4. Any related issues or PRs
