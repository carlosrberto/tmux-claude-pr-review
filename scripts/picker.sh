#!/usr/bin/env bash
#
# fzf picker (run inside a tmux display-popup). Lists open PRs from
# list_prs.sh, previews the highlighted PR with `gh pr view`, and on selection
# hands off to open_review.sh to spin up the review session. Each PR is marked
# with its watch-mode status; ctrl-r re-reviews it in a fresh window, ctrl-o
# opens it on GitHub (the popup stays open).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"
# shellcheck source=scripts/state.sh
. "$DIR/state.sh"

PREVIEW_WIDTH="$(tmux show-option -gqv @claude-pr-review-preview-width)"
[ -n "$PREVIEW_WIDTH" ] || PREVIEW_WIDTH="60%"

# Shown in the popup while the (network-bound) gh query runs, until fzf starts
# and takes over the screen.
printf '\n  Loading open PRs…\n'

# list_prs.sh prints PRs on stdout, or an error on stderr with non-zero exit.
if ! list="$("$DIR/list_prs.sh" 2>&1)"; then
  tmux display-message "claude-pr-review: ${list:-failed to list PRs}"
  exit 0
fi
if [ -z "$list" ]; then
  tmux display-message "claude-pr-review: no open PRs found"
  exit 0
fi

# "url<TAB>status" for every tracked PR. Passed via the environment: BSD awk
# rejects newlines in -v values.
PR_STATUSES="$(for k in $(pr_keys); do printf '%s\t%s\n' "$(pr_get "$k" url)" "$(pr_get "$k" status)"; done)"

# Raw fields: 1=url 2=repoWithOwner 3=repoName 4=number 5=title 6=author.
# Project to a hidden url (field 1, drives the preview and the action) plus an
# aligned display block "mark repoName#number  @author  title" (field 2, shown).
export PR_STATUSES
display="$(printf '%s\n' "$list" | awk -F'\t' '
BEGIN {
  mark["queued"] = "⧗"; mark["reviewing"] = "⟳"; mark["attention"] = "⚠"
  mark["done"] = "✓"; mark["updated"] = "↻"; mark["seen"] = "·"; mark["baseline"] = "○"
  n = split(ENVIRON["PR_STATUSES"], lines, "\n")
  for (i = 1; i <= n; i++) { split(lines[i], kv, "\t"); status[kv[1]] = kv[2] }
}
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
    m = (f[1] in status && status[f[1]] in mark) ? mark[status[f[1]]] : " "
    printf "%s\t%s %s  %s  %s\n", f[1], m, sprintf(f1, c1), sprintf(f2, c2), f[5]
  }
}')"

sel="$(printf '%s\n' "$display" | fzf \
  --ansi \
  --layout=reverse \
  --delimiter='\t' \
  --with-nth='2..' \
  --preview="'$DIR/pr_preview.sh' {1}" \
  --preview-window="right,${PREVIEW_WIDTH},wrap" \
  --expect=ctrl-r \
  --bind='ctrl-o:execute-silent(gh pr view --web {1} >/dev/null 2>&1 &)' \
  --header='enter: open review   ctrl-r: re-review   ctrl-o: open on GitHub   esc: cancel
⟳ reviewing  ✓ done  ↻ new pushes  ⚠ needs you  ⧗ queued  ○ pending  · seen')" || exit 0

key="$(printf '%s\n' "$sel" | sed -n 1p)"
url="$(printf '%s\n' "$sel" | sed -n 2p | cut -f1)"
[ -n "$url" ] || exit 0

if [ "$key" = "ctrl-r" ]; then
  exec "$DIR/open_review.sh" --replace "$url"
fi
exec "$DIR/open_review.sh" "$url"
