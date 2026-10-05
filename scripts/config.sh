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
#   set -g @claude-pr-review-notify             'tmux system'   # + terminal, cmd
#   set -g @claude-pr-review-notify-cmd         ''         # for the cmd channel
#   set -g @claude-pr-review-notify-click       'window'   # terminal-notifier click: window | github
#   set -g @claude-pr-review-notify-app         ''         # terminal app bundle id to activate (auto)
#   set -g @claude-pr-review-claude-config-dir  ''         # CLAUDE_CONFIG_DIR for review windows
#   set -g @claude-pr-review-state-dir          ''         # default: $XDG_STATE_HOME/tmux-claude-pr-review

# Every option the plugin reads (without the @claude-pr-review- prefix). Read in
# one tmux call (load_cfg); doctor.sh flags any other @claude-pr-review-* option.
CFG_OPTIONS="key width height preview-width preview-style repos filter clone-base
session cmd claude-name claude-config-dir state-dir worktree watch watch-key
status-key watch-repos watch-filter watch-interval watch-max watch-skip-drafts
watch-skip-authors watch-skip-labels notify notify-cmd notify-click notify-app
status-off status-idle
status-error"

# load_cfg - read every option in CFG_OPTIONS with a single `tmux
# display-message` (one fork instead of one per lookup) into _CFG_<name>
# variables. Runs when sourced; long-lived processes (the poller) re-run it to
# pick up config changes.
load_cfg() {
  local fmt="" sep name rest val
  sep="$(printf '\037')"
  for name in $CFG_OPTIONS; do fmt="$fmt#{@claude-pr-review-$name}$sep"; done
  rest="$(tmux display-message -p "$fmt" 2>/dev/null)" || return 0
  for name in $CFG_OPTIONS; do
    val="${rest%%"$sep"*}"; rest="${rest#*"$sep"}"
    printf -v "_CFG_${name//-/_}" '%s' "$val"
  done
  _CFG_LOADED=1
}
load_cfg

# _opt <@option> -> its value (from load_cfg for known options).
_opt() {
  local name="${1#@claude-pr-review-}" var
  var="_CFG_${name//-/_}"
  if [ -n "${_CFG_LOADED:-}" ] && [ "$name" != "$1" ] && [ -n "${!var+x}" ]; then
    printf '%s' "${!var}"
  else
    tmux show-option -gqv "$1" 2>/dev/null || true
  fi
}

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
    notify)            _or "$(_opt @claude-pr-review-notify)" "tmux system" ;;
    notify_cmd)        _opt @claude-pr-review-notify-cmd ;;
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
    notify)             v="$(cfg notify)" ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$v" | tr ',' ' ' | tr -s '[:space:]' '\n' | grep -v '^$' || true
}

# find_clone <owner> <repo> -> the local clone to use for owner/repo, or empty.
# Folders in clone_base are searched in order (up to 3 levels deep); a dir
# whose origin is owner/repo wins over one that only has the repo's name.
find_clone() {
  local want base c first=""
  want="$(printf '%s/%s' "$1" "$2" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r base; do
    base="$(_expand_home "$base")"
    [ -d "$base" ] || continue
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      [ -e "$c/.git" ] || continue
      [ -n "$first" ] || first="$c"
      if [ "$(origin_slug "$c")" = "$want" ]; then printf '%s' "$c"; return 0; fi
    done <<EOF
$(find "$base" -maxdepth 3 -type d -name "$2" -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
EOF
  done <<EOF
$(cfg_list clone_base)
EOF
  printf '%s' "$first"
}

# origin_slug <dir> -> lowercase "owner/repo" of the dir's origin remote (any
# URL form: https, ssh, or an ssh host alias like git@github-work:owner/repo).
origin_slug() {
  local u
  u="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 0
  u="${u%.git}"; u="${u%/}"
  printf '%s/%s' "$(basename "$(printf '%s' "${u%/*}" | tr ':' '/')")" "${u##*/}" | tr '[:upper:]' '[:lower:]'
}
