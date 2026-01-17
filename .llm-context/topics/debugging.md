# Debugging

## Overview
Tips and techniques for debugging para-llm-directory scripts and troubleshooting common issues.

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
