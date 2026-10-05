#!/usr/bin/env bash
#
# Record a review's progress. Called by:
#
#   Claude Code hooks (install_hooks.sh), from inside a review window's claude:
#     mark.sh done        Stop: the review turn finished
#     mark.sh attention   Notification: claude is waiting (e.g. a permission prompt)
#   (the PR key comes from $CLAUDE_PR_REVIEW_KEY, set by open_review.sh)
#
#   tmux hooks (claude_pr_review.tmux), when a review window gets focus:
#     mark.sh seen <key>
#
# Unknown keys and non-matching transitions are ignored, and it always exits 0
# so it can never break a Claude session.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"
# shellcheck source=scripts/state.sh
. "$DIR/state.sh"

event="${1:-}"
key="${2:-${CLAUDE_PR_REVIEW_KEY:-}}"
[ -n "$key" ] && pr_exists "$key" || exit 0

status="$(pr_get "$key" status)"
window="$(pr_get "$key" window)"
label="$(pr_get "$key" repo)#$(pr_get "$key" number)"
label="${label#*/}"
title="$(pr_get "$key" title)"

# being_viewed -> 0 if the review window is the active window of an attached session.
being_viewed() {
  local v
  v="$(tmux display-message -p -t "$window" '#{window_active} #{session_attached}' 2>/dev/null)" || return 1
  [ "${v%% *}" = "1" ] && [ "${v#* }" != "0" ]
}

case "$event:$status" in
  done:reviewing | done:attention)
    if being_viewed; then
      pr_set "$key" status seen
    else
      pr_set "$key" status "done"
      notify "done" "✓ review ready: $label${title:+ - $title}" "$key"
    fi
    # A slot freed up: start the next queued review now, not at the next poll.
    "$DIR/watch.sh" dispatch >/dev/null 2>&1 &
    ;;
  attention:reviewing)
    pr_set "$key" status attention
    being_viewed || notify attention "⚠ review needs attention: $label" "$key"
    ;;
  seen:done)
    # The tmux hooks also fire for background select-window calls.
    being_viewed || exit 0
    pr_set "$key" status seen
    ;;
  *) exit 0 ;;
esac

render_status
exit 0
