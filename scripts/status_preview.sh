#!/usr/bin/env bash
#
# fzf preview for status_picker.sh: the bottom of the PR's review window (live,
# with colors), or the rendered PR (pr_preview.sh) when it has no open window.
#
#   status_preview.sh <pr-key>
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"
# shellcheck source=scripts/state.sh
. "$DIR/state.sh"

key="${1:-}"
pr_exists "$key" || { printf '\n  Nothing to preview.\n'; exit 0; }
window="$(pr_get "$key" window)"

if window_alive "$window"; then
  # -J joins wrapped lines so fzf can re-wrap them for the preview width.
  tmux capture-pane -p -e -J -t "$window" -S -500 | awk 'NF { last = NR } { l[NR] = $0 } END { for (i = 1; i <= last; i++) print l[i] }' \
    | tail -n "${FZF_PREVIEW_LINES:-40}"
else
  printf '(no review window open)\n\n'
  "$DIR/pr_preview.sh" "$(pr_get "$key" url)"
fi
