#!/usr/bin/env bash
# filter-pane-text.sh - strip ANSI escapes and REPL chrome from captured pane
# text (stdin -> stdout). Shared by extract-latest.sh (Ctrl+b p) and
# stream-watcher.sh (Ctrl+b o) so the two paths can't drift apart.

perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\r//g' \
    | sed \
        -e '/^[[:space:]]*$/d' \
        -e '/esc to interrupt/d' \
        -e '/ctrl.*enter/d' \
        -e '/shift.*tab/d' \
        -e '/Press enter to continue/d' \
        -e '/Do you trust the contents of this directory/d' \
        -e '/Working with untrusted contents/d' \
        -e '/project-local config, hooks, and exec policies/d' \
        -e '/^[[:space:]]*[›>]*[[:space:]]*[12]\. \(Yes, continue\|No, quit\)/d' \
        -e '/^[[:space:]]*[╭╰│]/d'
