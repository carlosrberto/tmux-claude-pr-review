#!/usr/bin/env bash
# Sourced by the other scripts. Locates the config file and provides cfg().
#
# Resolution order:
#   1. tmux option @claude-pr-review-config
#   2. $XDG_CONFIG_HOME/tmux-claude-pr-review/config (or ~/.config/...)

_cpr_find_config() {
  local c
  c="$(tmux show-option -gqv @claude-pr-review-config 2>/dev/null || true)"
  [ -n "$c" ] || c="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-claude-pr-review/config"
  printf '%s' "$c"
}

CONFIG="$(_cpr_find_config)"

# cfg <key> -> trimmed value of the first `key = value` line (empty if missing).
cfg() {
  [ -f "$CONFIG" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG" | sed 's/[[:space:]]*$//' | head -1
}
