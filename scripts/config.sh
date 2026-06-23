#!/usr/bin/env bash
# Sourced by the other scripts. Configuration comes from tmux user options
# (set in tmux.conf), e.g.:
#
#   set -g @claude-pr-review-repos      'your-org/web-app your-org/api'
#   set -g @claude-pr-review-filter     'review-requested'
#   set -g @claude-pr-review-limit      '50'
#   set -g @claude-pr-review-clone-base '~/projects'
#   set -g @claude-pr-review-session    'Code Review'
#   set -g @claude-pr-review-cmd        '/review'

_opt() { tmux show-option -gqv "$1" 2>/dev/null || true; }

# cfg <logical-key> -> value of the matching tmux option (empty if unset).
cfg() {
  case "$1" in
    filter)         _opt @claude-pr-review-filter ;;
    limit)          _opt @claude-pr-review-limit ;;
    session)        _opt @claude-pr-review-session ;;
    review_command) _opt @claude-pr-review-cmd ;;
    clone_base)     _opt @claude-pr-review-clone-base ;;
    *) ;;
  esac
}

# cfg_list <logical-key> -> one value per line (option split on commas/whitespace).
cfg_list() {
  case "$1" in
    repos) _opt @claude-pr-review-repos | tr ',' ' ' | tr -s '[:space:]' '\n' | grep -v '^$' || true ;;
    *) ;;
  esac
}
