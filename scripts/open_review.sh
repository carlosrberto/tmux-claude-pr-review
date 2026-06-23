#!/usr/bin/env bash
#
# Open (or focus) a Claude Code review session for a pull request.
#
# This is the plugin's public entry point for the "launch a review" action — the
# picker calls it, and it's safe to call directly from your own automations.
#
#   open_review.sh [-b|--background] <pr-url>
#   open_review.sh [-b|--background] <owner/repo> <number>
#   open_review.sh [-b|--background] <owner/repo>#<number>
#
# It ensures a tmux session (default "Code Review") exists, then a window named
# "<repo-name>#<pr-number>" inside it. A freshly created window starts in the
# repo's local clone (found under clone_base, else $HOME) and launches:
#
#     claude "/review <pr-url>"
#
# An already-open window is just focused again — Claude is not relaunched.
#
# Options:
#   -b, --background   Create the session/window and start Claude, but do NOT
#                      switch the current client to it (stays out of your way;
#                      also works with no client attached, e.g. from cron).
#
# On success the target is printed as "<session>:<window>" (and the pane id on
# stderr-free stdout is available via --print-pane).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"

background=0
print_pane=0
dry_run=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -b | --background) background=1; shift ;;
    --print-pane) print_pane=1; shift ;;
    -n | --dry-run) dry_run=1; shift ;;
    -h | --help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do args+=("$1"); shift; done ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

[ "${#args[@]}" -ge 1 ] || { echo "usage: ${0##*/} [-b|--background] <pr-url | owner/repo number | owner/repo#number>" >&2; exit 2; }

# --- Resolve owner / repo / number / url from the arguments ---------------
spec="${args[0]}"
owner=""; repo=""; number=""; url=""
case "$spec" in
  http*://*/pull/*)
    url="${spec%%\?*}"; url="${url%%#*}"        # strip query/fragment
    rest="${url#*://}"; rest="${rest#*/}"        # owner/repo/pull/number...
    owner="${rest%%/*}"; rest="${rest#*/}"
    repo="${rest%%/*}"; rest="${rest#*/pull/}"
    number="${rest%%/*}"
    ;;
  */*)
    owner="${spec%%/*}"
    rest="${spec#*/}"                            # repo  or  repo#number
    repo="${rest%%#*}"
    if [ "$rest" != "$repo" ]; then              # had a #number
      number="${rest#*#}"
    else
      number="${args[1]:-}"
    fi
    url="https://github.com/${owner}/${repo}/pull/${number}"
    ;;
  *)
    echo "could not parse PR reference: '$spec'" >&2; exit 2 ;;
esac

case "$number" in
  '' | *[!0-9]*) echo "could not determine PR number from: '$spec'" >&2; exit 2 ;;
esac
[ -n "$repo" ] || { echo "could not determine repo from: '$spec'" >&2; exit 2; }

# --- Config-driven settings -----------------------------------------------
session="$(cfg session)"; [ -n "$session" ] || session="Code Review"
review_cmd="$(cfg review_command)"; [ -n "$review_cmd" ] || review_cmd="/review"
clone_base="$(cfg clone_base)"; [ -n "$clone_base" ] || clone_base="$HOME/projects"
clone_base="${clone_base/#\~/$HOME}"

win="${repo}#${number}"

# Working directory: first local clone named after the repo, else $HOME.
dir="$(find "$clone_base" -maxdepth 3 -type d -name "$repo" 2>/dev/null | grep -v '/\.git' | head -1 || true)"
[ -n "$dir" ] || dir="$HOME"

launch_cmd="claude \"${review_cmd} ${url}\""

if [ "$dry_run" -eq 1 ]; then
  printf 'session:    %s\n' "$session"
  printf 'window:     %s\n' "$win"
  printf 'cwd:        %s\n' "$dir"
  printf 'url:        %s\n' "$url"
  printf 'launch:     %s\n' "$launch_cmd"
  printf 'background: %s\n' "$([ "$background" -eq 1 ] && echo yes || echo no)"
  exit 0
fi

# --- Ensure the session + window ------------------------------------------
new=0
if ! tmux has-session -t "=$session" 2>/dev/null; then
  pane="$(tmux new-session -d -P -F '#{pane_id}' -s "$session" -n "$win" -c "$dir")"
  new=1
else
  pane="$(tmux list-windows -t "=$session" -F '#{window_name}	#{pane_id}' \
    | awk -F'\t' -v w="$win" '$1 == w { print $2; exit }')"
  if [ -z "$pane" ]; then
    pane="$(tmux new-window -d -P -F '#{pane_id}' -t "=$session:" -n "$win" -c "$dir")"
    new=1
  fi
fi

# Type the launch line into the fresh shell (ready immediately) so we never race
# Claude's TUI startup; only for a newly created window.
if [ "$new" -eq 1 ]; then
  tmux send-keys -t "$pane" "$launch_cmd" Enter
fi

# Focus the window within its (review) session — harmless to the current view.
tmux select-window -t "$pane"

# Foreground: pull the current client over to the review session.
if [ "$background" -eq 0 ]; then
  tmux switch-client -t "$session" 2>/dev/null \
    || echo "note: no client attached; '$session' created/updated detached" >&2
fi

if [ "$print_pane" -eq 1 ]; then
  printf '%s\n' "$pane"
else
  printf '%s:%s\n' "$session" "$win"
fi
