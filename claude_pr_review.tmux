#!/usr/bin/env bash
#
# Plugin entry point, sourced by TPM (Tmux Plugin Manager) at tmux start.
# Binds a key (default: prefix + R) that opens a popup listing open PRs for the
# configured repos; selecting one opens a Claude review session. Also wires up
# watch mode (auto-review): its toggle key, status segment and poller.
#
# The plugin version lives in the top-level VERSION file.
#
# Configure with:  set -g @claude-pr-review-key 'R'
#                  set -g @claude-pr-review-watch-key 'W'
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEY="$(tmux show-option -gqv @claude-pr-review-key)"
[ -n "$KEY" ] || KEY="R"

POPUP_W="$(tmux show-option -gqv @claude-pr-review-width)"
[ -n "$POPUP_W" ] || POPUP_W="60%"

POPUP_H="$(tmux show-option -gqv @claude-pr-review-height)"
[ -n "$POPUP_H" ] || POPUP_H="85%"

tmux bind-key "$KEY" display-popup -E -w "$POPUP_W" -h "$POPUP_H" "$CURRENT_DIR/scripts/picker.sh"

# --- Watch mode ------------------------------------------------------------

WATCH_KEY="$(tmux show-option -gqv @claude-pr-review-watch-key)"
[ -z "$WATCH_KEY" ] || tmux bind-key "$WATCH_KEY" run-shell -b "'$CURRENT_DIR/scripts/watch.sh' toggle"

STATUS_KEY="$(tmux show-option -gqv @claude-pr-review-status-key)"
[ -z "$STATUS_KEY" ] || tmux bind-key "$STATUS_KEY" display-popup -E -w "$POPUP_W" -h "$POPUP_H" "$CURRENT_DIR/scripts/status_picker.sh"

# #{claude_pr_review_status} in status-left/right -> the option the watcher
# keeps current (read from memory, no per-refresh script).
# (Pattern and replacement live in variables: bash 3.2 keeps backslashes
# written inline in a ${//} replacement.)
placeholder='#{claude_pr_review_status}'
replacement='#{@claude-pr-review-status}'
for side in status-left status-right; do
  val="$(tmux show-option -gqv "$side")"
  case "$val" in
    *"$placeholder"*) tmux set-option -g "$side" "${val//"$placeholder"/$replacement}" ;;
  esac
done

# Mark a finished review "seen" once its window is looked at. Fixed hook-array
# indexes keep reloads idempotent and leave the user's own hooks alone.
SEEN="if-shell -F '#{@claude-pr-review-key}' \"run-shell -b \\\"'$CURRENT_DIR/scripts/mark.sh' seen '#{@claude-pr-review-key}'\\\"\""
tmux set-hook -g 'session-window-changed[71]' "$SEEN"
tmux set-hook -g 'client-session-changed[71]' "$SEEN"

# (Re)start the poller - it only runs when watch is on - and draw the status.
tmux run-shell -b "'$CURRENT_DIR/scripts/watch.sh' start"
