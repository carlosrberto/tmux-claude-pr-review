#!/usr/bin/env bash
# Sourced by the other scripts. Configuration comes from tmux user options
# (set in tmux.conf), e.g.:
#
#   set -g @claude-pr-review-repos      'your-org/web-app your-org/api'
#   set -g @claude-pr-review-filter     ''      # picker's "yours" list; default: watch filter
#   set -g @claude-pr-review-clone-base '~/projects ~/work'   # searched in order
#   set -g @claude-pr-review-session    'Code Review'
#   set -g @claude-pr-review-cmd        '/review'
#
# Watch mode (auto-review):
#
#   set -g @claude-pr-review-watch              'off'      # initial state; the toggle persists
#   set -g @claude-pr-review-watch-key          ''         # e.g. 'W' -> prefix + W toggles
#   set -g @claude-pr-review-status-key         ''         # e.g. 'P' -> prefix + P tracked-PR popup
#   set -g @claude-pr-review-watch-repos        ''         # owner/name[:filter] ...; defaults to repos
#   set -g @claude-pr-review-watch-filter       'mine'     # filter for repos without :filter
#   set -g @claude-pr-review-watch-interval     '300'      # seconds between polls
#   set -g @claude-pr-review-watch-max          '2'        # concurrent auto-opened reviews
#   set -g @claude-pr-review-watch-skip-drafts  'on'
#   set -g @claude-pr-review-watch-skip-authors '@me dependabot renovate'
#   set -g @claude-pr-review-watch-skip-labels  ''
#   set -g @claude-pr-review-notify             'tmux macos'
#   set -g @claude-pr-review-claude-config-dir  ''         # CLAUDE_CONFIG_DIR for review windows
#   set -g @claude-pr-review-state-dir          ''         # default: $XDG_STATE_HOME/tmux-claude-pr-review

_opt() { tmux show-option -gqv "$1" 2>/dev/null || true; }

# _or <value> <default> -> value, or default when value is empty.
_or() { if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# _expand_home <path> -> path with a leading ~ replaced by $HOME.
_expand_home() { printf '%s' "${1/#\~/$HOME}"; }

# cfg <logical-key> -> value of the matching tmux option. The watch keys apply
# their defaults here; the original keys resolve defaults at the call site.
cfg() {
  case "$1" in
    filter)            _opt @claude-pr-review-filter ;;
    session)           _opt @claude-pr-review-session ;;
    review_command)    _opt @claude-pr-review-cmd ;;
    watch)             _or "$(_opt @claude-pr-review-watch)" off ;;
    watch_key)         _opt @claude-pr-review-watch-key ;;
    watch_filter)      _or "$(_opt @claude-pr-review-watch-filter)" mine ;;
    watch_interval)    _or "$(_opt @claude-pr-review-watch-interval)" 300 ;;
    watch_max)         _or "$(_opt @claude-pr-review-watch-max)" 2 ;;
    watch_skip_drafts) _or "$(_opt @claude-pr-review-watch-skip-drafts)" on ;;
    notify)            _or "$(_opt @claude-pr-review-notify)" "tmux macos" ;;
    status_off)        _or "$(_opt @claude-pr-review-status-off)" "PR ⏸" ;;
    status_idle)       _or "$(_opt @claude-pr-review-status-idle)" "PR 👁" ;;
    status_error)      _or "$(_opt @claude-pr-review-status-error)" "PR ✗" ;;
    claude_config_dir)
      _expand_home "$(_or "$(_opt @claude-pr-review-claude-config-dir)" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")" ;;
    state_dir)
      _expand_home "$(_or "$(_opt @claude-pr-review-state-dir)" "${XDG_STATE_HOME:-$HOME/.local/state}/tmux-claude-pr-review")" ;;
    *) ;;
  esac
}

# cfg_list <logical-key> -> one value per line (option split on commas/whitespace).
cfg_list() {
  local v
  case "$1" in
    repos)              v="$(_opt @claude-pr-review-repos)" ;;
    clone_base)         v="$(_or "$(_opt @claude-pr-review-clone-base)" "$HOME/projects")" ;;
    watch_repos)        v="$(_or "$(_opt @claude-pr-review-watch-repos)" "$(_opt @claude-pr-review-repos)")" ;;
    watch_skip_authors) v="$(_or "$(_opt @claude-pr-review-watch-skip-authors)" "@me dependabot renovate")" ;;
    watch_skip_labels)  v="$(_opt @claude-pr-review-watch-skip-labels)" ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$v" | tr ',' ' ' | tr -s '[:space:]' '\n' | grep -v '^$' || true
}
