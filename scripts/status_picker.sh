#!/usr/bin/env bash
#
# fzf popup (prefix + @claude-pr-review-status-key) listing the PRs watch mode
# tracks, most urgent first. The preview is a live capture of the PR's review
# window (gh pr view when it has none).
#
#   enter   jump to the review window (or open a review)
#   ctrl-r  re-review in a fresh window
#   ctrl-o  open the PR on GitHub (the popup stays open)
#   ctrl-x  forget the PR (closes its review window)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"
# shellcheck source=scripts/state.sh
. "$DIR/state.sh"

PREVIEW_WIDTH="$(tmux show-option -gqv @claude-pr-review-preview-width)"
[ -n "$PREVIEW_WIDTH" ] || PREVIEW_WIDTH="60%"

# rank <status> -> sort order: needs you, unread, running, new pushes, waiting, rest.
rank() {
  case "$1" in
    attention) echo 1 ;; done) echo 2 ;; reviewing) echo 3 ;; updated) echo 4 ;;
    queued) echo 5 ;; seen) echo 6 ;; *) echo 7 ;;
  esac
}

# mark <status> -> the icon also used in the status line and the PR picker.
mark() {
  case "$1" in
    queued) echo "⧗" ;; reviewing) echo "⟳" ;; attention) echo "⚠" ;;
    done) echo "✓" ;; updated) echo "↻" ;; seen) echo "·" ;; *) echo " " ;;
  esac
}

# header -> watch state and the last poll, so a "PR ✗" is explained here.
header() {
  local poll t msg ago
  poll="$(cat "$STATE_DIR/last-poll" 2>/dev/null || true)"
  if [ -z "$poll" ]; then
    msg="never polled"
  else
    t="${poll%% *}"; ago=$(( ($(now) - t) / 60 ))
    msg="last poll ${ago}m ago: ${poll#* }"
  fi
  printf 'watch %s · %s%s\n' "$(watch_enabled && echo on || echo off)" "$msg" \
    "$(config_dir_ok || printf ' · no settings.json in %s' "$(cfg claude_config_dir)")"
  printf 'enter: open   ctrl-r: re-review   ctrl-o: GitHub   ctrl-x: forget   esc: close\n'
  printf '⚠ needs you  ✓ done  ⟳ reviewing  ↻ new pushes  ⧗ queued  · seen'
}

# Hidden fields: 1=key 2=url; shown: 3="mark repo#num  status  title" (aligned).
rows() {
  local k s label
  for k in $(pr_keys); do
    s="$(pr_get "$k" status)"
    [ "$s" = "baseline" ] && continue
    label="$(pr_get "$k" repo)#$(pr_get "$k" number)"; label="${label#*/}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(rank "$s")" "$k" "$(pr_get "$k" url)" \
      "$(mark "$s")" "$label" "$s" "$(pr_get "$k" title)"
  done | sort -t"$(printf '\t')" -k1,1n -k2,2 | awk -F'\t' '
    { rows[NR] = $0; if (length($5) > w) w = length($5) }
    END {
      # The icon is padded apart from the label: BSD awk counts bytes, and the
      # icons differ in byte length.
      for (i = 1; i <= NR; i++) {
        split(rows[i], f, "\t")
        printf "%s\t%s\t%s %-" w "s  %-9s  %s\n", f[2], f[3], f[4], f[5], f[6], f[7]
      }
    }'
}

while :; do
  list="$(rows)"
  if [ -z "$list" ]; then
    tmux display-message "claude-pr-review: no tracked PRs$(watch_enabled || echo ' (watch is off)')"
    exit 0
  fi

  sel="$(printf '%s\n' "$list" | fzf \
    --ansi \
    --layout=reverse \
    --delimiter='\t' \
    --with-nth='3..' \
    --preview="'$DIR/status_preview.sh' {1}" \
    --preview-window="right,${PREVIEW_WIDTH},wrap,follow" \
    --expect=ctrl-r,ctrl-x \
    --bind='ctrl-o:execute-silent(gh pr view --web {2} >/dev/null 2>&1 &)' \
    --header="$(header)")" || exit 0

  key="$(printf '%s\n' "$sel" | sed -n 1p)"
  line="$(printf '%s\n' "$sel" | sed -n 2p)"
  [ -n "$line" ] || exit 0
  pr="$(printf '%s' "$line" | cut -f1)"
  url="$(printf '%s' "$line" | cut -f2)"
  window="$(pr_get "$pr" window)"

  case "$key" in
    ctrl-r) exec "$DIR/open_review.sh" --replace "$url" ;;
    ctrl-x)
      window_alive "$window" && tmux kill-window -t "$window"
      pr_rm "$pr"
      render_status
      continue ;;
    *)
      if window_alive "$window"; then
        tmux switch-client -t "$window" 2>/dev/null
        tmux select-window -t "$window"
        exit 0
      fi
      exec "$DIR/open_review.sh" "$url" ;;
  esac
done
