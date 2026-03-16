#!/bin/bash
# claudetop-iterm-hook.sh — iTerm2 integration for claudetop
#
# Source this in your shell profile (~/.bashrc, ~/.zshrc, or ~/.bash_profile):
#   source ~/.claude/claudetop-iterm-hook.sh
#
# Saves the current terminal's TTY device path so the background watcher
# can write escape sequences directly to this terminal.

if [ -n "${ITERM_SESSION_ID:-}" ] && [ -n "${CLAUDETOP_ITERM:-}" ]; then
  # Record this terminal's TTY so the watcher knows where to write
  _MY_TTY=$(tty 2>/dev/null)
  if [ -n "$_MY_TTY" ] && [ "$_MY_TTY" != "not a tty" ]; then
    echo "${ITERM_SESSION_ID}=${_MY_TTY}" >> "$HOME/.claude/claudetop-iterm-ttys"
    # Deduplicate (keep latest per session)
    if [ -f "$HOME/.claude/claudetop-iterm-ttys" ]; then
      awk -F= '!seen[$1]++' <(tac "$HOME/.claude/claudetop-iterm-ttys") | tac > "$HOME/.claude/claudetop-iterm-ttys.tmp"
      mv "$HOME/.claude/claudetop-iterm-ttys.tmp" "$HOME/.claude/claudetop-iterm-ttys"
    fi
  fi

  # Clean up on shell exit: reset terminal and remove TTY mapping
  trap 'printf "\033]1;\007\033]1337;SetBadgeFormat=\007\033]1337;SetColors=bg=default\007"; sed -i "" "/^${ITERM_SESSION_ID}=/d" "$HOME/.claude/claudetop-iterm-ttys" 2>/dev/null' EXIT
fi
