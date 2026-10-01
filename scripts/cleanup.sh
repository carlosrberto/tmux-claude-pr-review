#!/usr/bin/env bash
#
# Clean up finished reviews: close each one's review window and remove its
# review worktree (+ branch). Local only - no GitHub calls, no poll.
#
#   cleanup.sh [--dry-run]       every reviewed PR (done, seen, updated)
#   cleanup.sh [--dry-run] <key> just that PR
#
# PRs stay tracked (done -> seen; updated stays updated), so the next poll
# doesn't take them for new review requests. The worktree is
# <clone>/@claude-pr-review-worktree, default .claude/worktrees/pr-review-{number}
# (the uux-dev pr-review convention; the branch is named after its dir). It is
# only removed when git lists it as a worktree of that clone.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"
# shellcheck source=scripts/state.sh
. "$DIR/state.sh"

dry_run=0
case "${1:-}" in -n | --dry-run) dry_run=1; shift ;; esac

pattern="$(_opt @claude-pr-review-worktree)"
[ -n "$pattern" ] || pattern=".claude/worktrees/pr-review-{number}"

# clone_of <key> -> the clone the review ran in (recorded at launch; else the
# review window's current path).
clone_of() {
  local c w
  c="$(pr_get "$1" clone)"
  if [ -z "$c" ]; then
    w="$(pr_get "$1" window)"
    window_alive "$w" && c="$(tmux display-message -p -t "$w" '#{pane_current_path}')"
  fi
  [ -n "$c" ] && git -C "$c" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##'
}

# clean_one <key> - prints what it did, one line.
clean_one() {
  local key="$1" w clone wt done_what="" label
  label="$(pr_get "$key" repo)#$(pr_get "$key" number)"; label="${label#*/}"
  w="$(pr_get "$key" window)"
  clone="$(clone_of "$key")"
  wt=""
  [ -z "$clone" ] || wt="$clone/${pattern//\{number\}/$(pr_get "$key" number)}"

  if window_alive "$w"; then
    [ "$dry_run" -eq 1 ] || tmux kill-window -t "$w"
    done_what="window"
  fi
  if [ -n "$wt" ] && git -C "$clone" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt"; then
    if [ "$dry_run" -eq 0 ]; then
      git -C "$clone" worktree remove --force "$wt" 2>/dev/null || true
      git -C "$clone" branch -D "$(basename "$wt")" >/dev/null 2>&1 || true
      git -C "$clone" worktree prune 2>/dev/null || true
    fi
    done_what="${done_what:+$done_what + }worktree"
  fi

  if [ "$dry_run" -eq 0 ]; then
    case "$(pr_get "$key" status)" in
      done) pr_set "$key" status seen window "" ;;
      *)    pr_set "$key" window "" ;;
    esac
    log "cleaned up $label (${done_what:-nothing to remove})"
  fi
  printf '%s: %s\n' "$label" "${done_what:-nothing to remove}"
}

if [ $# -ge 1 ]; then
  pr_exists "$1" || { echo "not tracked: $1" >&2; exit 1; }
  clean_one "$1"
else
  for key in $(pr_keys); do
    case "$(pr_get "$key" status)" in
      done | seen | updated) clean_one "$key" ;;
    esac
  done
fi

[ "$dry_run" -eq 1 ] || render_status
