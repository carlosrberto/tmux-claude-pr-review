#!/usr/bin/env bash
#
# fzf picker (run inside a tmux display-popup). Lists open PRs for the
# @claude-pr-review-repos repos (via watch_list.sh), previews the highlighted PR,
# and on selection hands off to open_review.sh to spin up the review session.
# Each PR is marked with its watch-mode status.
#
# Two lists, toggled with ctrl-a: yours (@claude-pr-review-filter, else the
# watch filter, default "mine"; with watch mode's skips) and all open PRs.
# ctrl-r re-reviews in a fresh window; ctrl-o opens the PR on GitHub.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"
# shellcheck source=scripts/state.sh
. "$DIR/state.sh"

PREVIEW_WIDTH="$(tmux show-option -gqv @claude-pr-review-preview-width)"
[ -n "$PREVIEW_WIDTH" ] || PREVIEW_WIDTH="60%"

mine_filter="$(_or "$(cfg filter)" "$(cfg watch_filter)")"
[ "$mine_filter" != "all" ] || mine_filter="$(cfg watch_filter)"
mode="mine"

# load_list -> sets $list for $mode: "url repoWithOwner repoName number sha
# author title" per PR, newest first within each repo. Exits on a gh error.
load_list() {
  local args err
  if [ "$mode" = "mine" ]; then args="--filter $mine_filter"; else args="--filter all --no-skips"; fi
  # Shown while the (network-bound) gh query runs, until fzf takes the screen.
  clear 2>/dev/null; printf '\n  Loading %s PRs…\n' "$([ "$mode" = "mine" ] && echo "your" || echo "all open")"
  err="$(mktemp "${TMPDIR:-/tmp}/claude-pr-review.XXXXXX")"
  # shellcheck disable=SC2086  # $args is a fixed set of single-token flags
  if ! list="$("$DIR/watch_list.sh" --repos repos $args 2>"$err")"; then
    tmux display-message "claude-pr-review: $(grep -v '^warning' "$err" | head -1)"
    rm -f "$err"
    exit 0
  fi
  rm -f "$err"
  list="$(printf '%s\n' "$list" | sort -t"$(printf '\t')" -k2,2 -k4,4nr | grep -v '^$')"
}

# "url<TAB>status" for every tracked PR. Passed via the environment: BSD awk
# rejects newlines in -v values.
PR_STATUSES="$(for k in $(pr_keys); do printf '%s\t%s\n' "$(pr_get "$k" url)" "$(pr_get "$k" status)"; done)"

export PR_STATUSES

# Raw fields: 1=url 2=repoWithOwner 3=repoName 4=number 5=sha 6=author 7=title.
# Project to a hidden url (field 1, drives the preview and the action) plus an
# aligned display block "mark repoName#number  @author  title" (field 2, shown).
render() {
  # Fallback row (empty hidden url): enter/ctrl-r on it do nothing.
  if [ -z "$list" ]; then
    if [ "$mode" = "mine" ]; then
      printf '\t  No open PRs waiting on you (%s) in these repos - ctrl-a shows all open PRs\n' "$mine_filter"
    else
      printf '\t  No open PRs in these repos (%s)\n' "$(cfg_list repos | tr '\n' ' ' | sed 's/ $//')"
    fi
    return 0
  fi
  printf '%s\n' "$list" | awk -F'\t' '
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
    printf "%s\t%s %s  %s  %s\n", f[1], m, sprintf(f1, c1), sprintf(f2, c2), f[7]
  }
}'
}

while :; do
  load_list
  if [ "$mode" = "mine" ]; then
    shown="showing: yours ($mine_filter, $(printf '%s' "$list" | grep -c .))   ctrl-a: all open PRs"
  else
    shown="showing: all open PRs ($(printf '%s' "$list" | grep -c .))   ctrl-a: yours ($mine_filter)"
  fi

  sel="$(render | fzf \
    --ansi \
    --layout=reverse \
    --delimiter='\t' \
    --with-nth='2..' \
    --preview="'$DIR/pr_preview.sh' {1}" \
    --preview-window="right,${PREVIEW_WIDTH},wrap" \
    --expect=ctrl-r,ctrl-a \
    --bind='ctrl-o:execute-silent([ -n {1} ] && gh pr view --web {1} >/dev/null 2>&1 &)' \
    --header="$shown
enter: open review   ctrl-r: re-review   ctrl-o: open on GitHub   esc: cancel
⟳ reviewing  ✓ done  ↻ new pushes  ⚠ needs you  ⧗ queued  ○ pending  · seen")" || exit 0

  key="$(printf '%s\n' "$sel" | sed -n 1p)"
  if [ "$key" = "ctrl-a" ]; then
    if [ "$mode" = "mine" ]; then mode="all"; else mode="mine"; fi
    continue
  fi
  url="$(printf '%s\n' "$sel" | sed -n 2p | cut -f1)"
  [ -n "$url" ] || continue   # the fallback row

  if [ "$key" = "ctrl-r" ]; then
    exec "$DIR/open_review.sh" --replace "$url"
  fi
  exec "$DIR/open_review.sh" "$url"
done
