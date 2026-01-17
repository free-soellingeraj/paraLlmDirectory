# CI/CD

## Overview
This project currently has no CI/CD pipeline configured. This document outlines potential CI/CD approaches if one is added in the future.

## Current State

- **No `.github/workflows/`**: No GitHub Actions configured
- **No build step**: Scripts are pure Bash, no compilation needed
- **No tests**: No automated test suite exists
- **Manual release**: Users clone the repo and run `install.sh`

---

## Potential CI/CD Setup

If CI/CD is added, consider these components:

### Linting
```yaml
# .github/workflows/lint.yml
- name: ShellCheck
  uses: ludeeus/action-shellcheck@master
  with:
    scandir: '.'
```

ShellCheck catches common Bash issues:
- Unquoted variables
- Deprecated syntax
- Portability issues

### Testing
Potential test scenarios:
- Script syntax validation: `bash -n script.sh`
- fzf mock testing (would need test harness)
- Integration tests in Docker with tmux

### Release Process
If releases are formalized:
1. Tag version: `git tag v1.0.0`
2. Create GitHub release
3. Users can then reference specific versions

---

## Manual Validation Checklist

Until automated CI/CD exists, validate manually:

- [ ] All scripts executable: `chmod +x *.sh`
- [ ] No syntax errors: `bash -n tmux-new-branch.sh`
- [ ] Test in fresh terminal
- [ ] Test in tmux popup
- [ ] Test create, resume, and cleanup flows
- [ ] Verify `envs.sh` output formatting

---

## When to Add CI/CD

Consider adding CI/CD when:
- Multiple contributors need code quality gates
- Releases need to be versioned and tracked
- Breaking changes need to be caught before merge
- Installation needs to support multiple platforms

---

## Notes

For this project, simplicity is a feature. A heavy CI/CD setup may be unnecessary given:
- No build artifacts
- No dependencies to install
- Direct script execution
- Single-platform focus (macOS with tmux)
# cicd

## Overview
<!-- Describe what this topic covers -->

## Details
<!-- Add detailed information here -->

**File**: <!-- path/to/relevant/file.ext:line -->
