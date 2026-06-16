# Debugging

## Overview
Tips and techniques for debugging para-llm-directory scripts and troubleshooting common issues.

## Diagnosing TTS Playback (Ctrl+b p) Hangs

When TTS "just beeps for a long time" without speaking, the prep phase is stuck.
A live indicator shows the current stage and a per-stage timer in the status
line, e.g. `TTS: summarizing via codex (14s)` — whichever stage the timer keeps
climbing on is the one hanging.

A timestamped trail of every stage is also written per pane:

```bash
cat /tmp/para-llm-tts/<pane>.progress.log
# %-stripped pane id, so pane %5 -> file 5.progress.log
cat /tmp/para-llm-tts/5.progress.log
```

Stages: `extracting pane text` → `summarizing via <backend>` → `generating
audio (edge-tts)` → `playing`. Common culprits:
- **summarizing** stalls → the LLM backend (`codex exec`; `claude -p` was
  retired, see ADR-009) is slow or hung; capped by `TTS_SUMMARIZE_TIMEOUT`
  (default 60s), then falls back to raw pane text. Set `TTS_SUMMARIZE=0` to skip
  the LLM step entirely, or ensure `codex` is on PATH if summaries are missing.
- **generating audio** stalls → `edge-tts` is a **network** call to Microsoft
  (`wss://speech.platform.bing.com`), so check connectivity; capped by
  `TTS_SYNTH_TIMEOUT` (default 60s).
- The "preparing" beep itself is hard-capped by `TTS_AMBIENT_MAX_SECONDS`
  (default 120s) regardless of cause.

Disable the indicator with `TTS_PROGRESS_ENABLED=0`. See BUG-018.

**File**: `plugins/tts/toggle-tts.sh` (`set_phase`, `start_progress_loop`)

## Running Scripts in Debug Mode

### Bash Debug Output
Add debug flags to see what's happening:

```bash
# Run with verbose output
bash -x ~/code/para-llm-directory/tmux-new-branch.sh

# Or add to the script temporarily:
set -x  # Enable debug output
set +x  # Disable debug output
```

### Test Outside tmux Popup
Run scripts directly in terminal instead of via `Ctrl+b c`:

```bash
# Test the new branch script
~/code/para-llm-directory/tmux-new-branch.sh

# Test cleanup script
~/code/para-llm-directory/tmux-cleanup-branch.sh

# Test envs status
~/code/para-llm-directory/envs.sh -v
```

---

## Common Issues and Solutions

### fzf Not Found
**Symptom**: Script exits immediately with no UI
**Solution**: Install fzf: `brew install fzf`

### "No remote 'origin' found"
**Symptom**: Error when trying to clone
**Cause**: Base repo doesn't have a remote configured
**Solution**: Add remote to base repo: `git remote add origin <url>`
**File**: `tmux-new-branch.sh:143-151`

### Popup Doesn't Appear
**Symptom**: `Ctrl+b c` does nothing
**Cause**: tmux version < 3.2 (no `display-popup` support)
**Solution**: Update tmux: `brew upgrade tmux`
**Check version**: `tmux -V`

### "← Back" Doesn't Work
**Symptom**: Selecting back doesn't navigate
**Cause**: Script exiting early
**Debug**: Run script directly and check exit codes

### Clone Directory Already Exists
**Symptom**: Error about existing directory
**Solution**: Either resume existing clone or manually delete:
```bash
rm -rf ~/code/envs/ProjectName-feature/
```

### tmux Window Not Named Correctly
**Symptom**: Window has wrong name
**Debug**: Check window names:
```bash
tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}'
```

---

## Useful Debug Commands

### Check Environment State
```bash
# List all environments
ls -la ~/code/envs/

# Check specific environment
ls -la ~/code/envs/ProjectName-feature/

# Check git status in environment
git -C ~/code/envs/ProjectName-feature/ProjectName status
```

### Check tmux State
```bash
# List all windows
tmux list-windows

# List all sessions and windows
tmux list-windows -a

# Check tmux config
tmux show-options -g | grep bind
```

### Check Git Remote
```bash
# In base repo
git -C ~/code/ProjectName remote -v

# In cloned environment
git -C ~/code/envs/ProjectName-feature/ProjectName remote -v
```

---

## Logging

Scripts currently don't have built-in logging. To add temporary logging:

```bash
# Add to script
exec > >(tee /tmp/para-llm-debug.log) 2>&1

# Or redirect when running
~/code/para-llm-directory/tmux-new-branch.sh 2>&1 | tee /tmp/debug.log
```

---

## Testing Changes

When modifying scripts:

1. **Test outside popup first**: Run script directly in terminal
2. **Use echo debugging**: Add `echo "DEBUG: $VARIABLE"` statements
3. **Check exit codes**: Add `echo "Exit code: $?"` after commands
4. **Test fzf separately**: `echo -e "opt1\nopt2" | fzf`
5. **Test in fresh tmux session**: Reload config with `tmux source-file ~/.tmux.conf`

---

## Rollback

If something breaks:

```bash
# Restore original tmux.conf
cp ~/.tmux.conf.backup ~/.tmux.conf
tmux source-file ~/.tmux.conf

# Or remove para-llm bindings manually
# Edit ~/.tmux.conf and remove the para-llm-directory section
```

---

## Testing from Feature Branch Environments

When developing new features for para-llm-directory itself, you can test changes by pointing your tmux bindings to a feature branch's scripts.

### How It Works

The `install.sh` script writes **absolute paths** to `~/.tmux.conf`. Running install from a feature branch directory makes tmux use that branch's scripts:

```bash
# From your feature branch environment
cd ~/code/envs/paraLlmDirectory-feature-xyz/paraLlmDirectory
./install.sh
```

This will:
1. Backup your existing `~/.tmux.conf`
2. **Remove** any existing para-llm-directory bindings
3. **Add new bindings** pointing to the feature branch directory
4. Reload tmux config

### Verify Which Scripts Are Active

```bash
# Check where bindings point
grep "para-llm-directory" ~/.tmux.conf

# You should see paths like:
# /Users/.../envs/paraLlmDirectory-feature-xyz/paraLlmDirectory/tmux-command-center.sh
```

### Workflow

1. **Create feature branch environment**: `Ctrl+b c` → paraLlmDirectory → New → feature-name
2. **Make changes** to scripts in the feature branch
3. **Install from feature branch**: `./install.sh`
4. **Test** using `Ctrl+b v`, `Ctrl+b c`, etc.
5. **Iterate** - changes take effect immediately (no reinstall needed for most changes)
6. **When done**: Install from main repo to restore normal bindings

### Risks and Considerations

| Risk | Mitigation |
|------|------------|
| Bugs in dev code affect tmux | Backup is created; can restore with `cp ~/.tmux.conf.backup ~/.tmux.conf` |
| Forgetting which install is active | Check with `grep para-llm ~/.tmux.conf \| head -1` |
| Deleting feature env breaks bindings | Reinstall from main repo before cleanup |
| Multiple developers/envs | Each install overwrites; only one can be active |

### Restoring Main Repo Bindings

```bash
# Option 1: Reinstall from main repo
cd ~/code/paraLlmDirectory
./install.sh

# Option 2: Restore backup
cp ~/.tmux.conf.backup ~/.tmux.conf
tmux source-file ~/.tmux.conf
```

**File**: `install.sh:36-48`
