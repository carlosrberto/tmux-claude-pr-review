#!/usr/bin/env bash
#
# fzf picker (run inside a tmux display-popup). Lists open PRs from
# list_prs.sh, previews the highlighted PR with `gh pr view`, and on selection
# hands off to open_review.sh to spin up the review session.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREVIEW_WIDTH="$(tmux show-option -gqv @claude-pr-review-preview-width)"
[ -n "$PREVIEW_WIDTH" ] || PREVIEW_WIDTH="60%"

# list_prs.sh prints PRs on stdout, or an error on stderr with non-zero exit.
if ! list="$("$DIR/list_prs.sh" 2>&1)"; then
  tmux display-message "claude-pr-review: ${list:-failed to list PRs}"
  exit 0
fi
if [ -z "$list" ]; then
  tmux display-message "claude-pr-review: no open PRs found"
  exit 0
fi

# Raw fields: 1=url 2=repoWithOwner 3=repoName 4=number 5=title 6=author.
# Project to a hidden url (field 1, drives the preview and the action) plus an
# aligned display block "repoName#number  @author  title" (field 2, shown).
display="$(printf '%s\n' "$list" | awk -F'\t' '
{
  rows[NR] = $0
  c1 = $3 "#" $4; c2 = "@" $6
  if (length(c1) > w1) w1 = length(c1)
  if (length(c2) > w2) w2 = length(c2)
}
END {
  f1 = "%-" w1 "s"; f2 = "%-" w2 "s"
  for (i = 1; i <= NR; i++) {
    split(rows[i], f, "\t")
    c1 = f[3] "#" f[4]; c2 = "@" f[6]
    printf "%s\t%s  %s  %s\n", f[1], sprintf(f1, c1), sprintf(f2, c2), f[5]
  }
}')"

sel="$(printf '%s\n' "$display" | fzf \
  --ansi \
  --layout=reverse \
  --delimiter='\t' \
  --with-nth='2..' \
  --preview='gh pr view {1}' \
  --preview-window="right,${PREVIEW_WIDTH},wrap" \
  --header='enter: open review session   esc: cancel')" || exit 0

[ -z "$sel" ] && exit 0

url="$(printf '%s' "$sel" | cut -f1)"
exec "$DIR/open_review.sh" "$url"
