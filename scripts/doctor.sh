#!/usr/bin/env bash
#
# Health check: is the plugin set up right, and if watch mode isn't reviewing,
# why? Read-only - changes nothing. Exits 1 if any check fails.
#
#   doctor.sh [--color]
#
# Also shown inside the tracked-PR popup (prefix + @claude-pr-review-status-key,
# then ctrl-g).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"
# shellcheck source=scripts/state.sh
. "$DIR/state.sh"

color=0
{ [ "${1:-}" = "--color" ] || [ -t 1 ]; } && color=1
if [ "$color" -eq 1 ]; then
  G=$'\033[32m' R=$'\033[31m' Y=$'\033[33m' B=$'\033[1m' D=$'\033[2m' N=$'\033[0m'
else
  G="" R="" Y="" B="" D="" N=""
fi
failed=0
ok()      { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
bad()     { printf '  %s✗%s %s\n' "$R" "$N" "$*"; failed=1; }
warn()    { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
section() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }

FILTERS=" mine review-requested review-requested-team assigned involves author all "
CHANNELS=" tmux system macos terminal cmd "
words() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
STYLES=" dark light dracula tokyo-night pink notty ascii auto "

# guess_option <unknown-name> -> a known option it was probably meant to be.
# (A function: bash 3.2 can't parse a case statement inside $(...).)
guess_option() {
  local k best=""
  # Same name ignoring a trailing s or the hyphens (statuskey -> status-key).
  for k in $CFG_OPTIONS; do
    [ "$k" = "${1%s}" ] || [ "${k//-/}" = "${1//-/}" ] && { echo "$k"; return 0; }
  done
  # One or two letters missing (notfy -> notify).
  for k in $CFG_OPTIONS; do
    if [ $(( ${#k} - ${#1} )) -ge 1 ] && [ $(( ${#k} - ${#1} )) -le 2 ] &&
      awk -v a="$1" -v b="$k" 'BEGIN { i = 1; for (j = 1; j <= length(b) && i <= length(a); j++) if (substr(a, i, 1) == substr(b, j, 1)) i++; exit !(i > length(a)) }'; then
      echo "$k"; return 0
    fi
  done
  # Else the longest known option sharing a prefix with it.
  for k in $CFG_OPTIONS; do
    case "$1" in "$k"*) [ "${#k}" -le "${#best}" ] || best="$k" ;; esac
    case "$k" in "$1"*) [ -n "$best" ] || best="$k" ;; esac
  done
  [ -z "$best" ] || echo "$best"
}

valid_filter() { case "$FILTERS" in *" $1 "*) return 0 ;; esac; return 1; }

# --- Config -------------------------------------------------------------------
section "Config"

set_opts="$(tmux show-options -g 2>/dev/null | awk '{ print $1 }' | grep '^@claude-pr-review-' | sort -u)"
for o in $set_opts; do
  name="${o#@claude-pr-review-}"
  [ "$name" = "status" ] && continue   # internal: the status segment text
  case " $(printf '%s' "$CFG_OPTIONS" | tr '\n' ' ') " in
    *" $name "*) printf '  %s%-28s%s %s\n' "$D" "$name" "$N" "$(_opt "$o")" ;;
    *)
      guess="$(guess_option "$name")"
      bad "unknown option $o${guess:+ - did you mean @claude-pr-review-$guess?}" ;;
  esac
done

[ -n "$(cfg_list repos)" ] || bad "@claude-pr-review-repos is empty - nothing to list or watch"
for spec in $( { cfg_list repos; cfg_list watch_repos; } | sort -u); do
  repo="${spec%%:*}"; f="${spec#"$repo"}"; f="${f#:}"
  case "$repo" in */*) ;; *) bad "repo '$spec' isn't owner/name" ;; esac
  [ -z "$f" ] || valid_filter "$f" || bad "repo '$spec': unknown filter '$f'"
done
for k in filter watch_filter; do
  v="$(cfg "$k")"
  [ -z "$v" ] || valid_filter "$v" || bad "${k//_/-} '$v' isn't a filter - use: $(words "$FILTERS")"
done
for k in watch_interval watch_max; do
  case "$(cfg "$k")" in '' | *[!0-9]* | 0) bad "${k//_/-} '$(cfg "$k")' isn't a positive number" ;; esac
done
for k in watch watch_skip_drafts; do
  case "$(cfg "$k")" in on | off) ;; *) bad "${k//_/-} '$(cfg "$k")' should be on or off" ;; esac
done
for ch in $(cfg_list notify); do
  case "$CHANNELS" in *" $ch "*) ;; *) bad "notify channel '$ch' unknown - use: $(words "$CHANNELS")" ;; esac
done
style="$(_opt @claude-pr-review-preview-style)"
[ -z "$style" ] || case "$STYLES" in *" $style "*) ;; *) warn "preview-style '$style' isn't a built-in glamour style" ;; esac
[ "$failed" -eq 0 ] && ok "options valid"

# --- Dependencies -------------------------------------------------------------
section "Dependencies"

tv="$(tmux -V 2>/dev/null | sed 's/[^0-9.]//g')"
case "$tv" in
  '' ) bad "tmux not found" ;;
  [0-2].* | 3.[01]*) bad "tmux $tv - 3.2+ is needed for popups" ;;
  *) ok "tmux $tv" ;;
esac
if command -v fzf >/dev/null 2>&1; then ok "fzf $(fzf --version | cut -d' ' -f1)"; else bad "fzf not found - the popups need it"; fi
if ! command -v gh >/dev/null 2>&1; then
  bad "gh not found - install the GitHub CLI"
elif login="$(gh api user --jq .login 2>/dev/null)"; then
  ok "gh logged in as $login (@me)"
else
  bad "gh can't reach GitHub as a logged-in user - run: gh auth status"
fi
if command -v claude >/dev/null 2>&1; then
  if claude --help 2>/dev/null | grep -q -- '--name'; then ok "claude $(claude --version 2>/dev/null | cut -d' ' -f1)"
  else warn "claude has no --name flag - update Claude Code (review sessions won't be named)"; fi
else
  bad "claude not found on PATH"
fi
if command -v jq >/dev/null 2>&1; then ok "jq (for install_hooks.sh)"; else warn "jq not found - only install_hooks.sh needs it"; fi

# --- Claude -------------------------------------------------------------------
section "Claude"

cdir="$(cfg claude_config_dir)"
settings="$cdir/settings.json"
if [ ! -f "$settings" ]; then
  bad "no settings.json in $cdir - set @claude-pr-review-claude-config-dir"
else
  ok "config dir $cdir"
  for ev in Stop Notification; do
    if command -v jq >/dev/null 2>&1; then
      n="$(jq --arg ev "$ev" '[.hooks[$ev][]?.hooks[]?.command // "" | select(contains("CLAUDE_PR_REVIEW_MARK"))] | length' "$settings" 2>/dev/null)"
    else
      n="$(grep -c 'CLAUDE_PR_REVIEW_MARK' "$settings")"
    fi
    if [ "${n:-0}" -gt 0 ]; then ok "$ev hook installed"
    else bad "$ev hook missing - run: $DIR/install_hooks.sh"; fi
  done
fi
ok "review command: $(_or "$(cfg review_command)" /review) <pr-url>"

# --- Repos --------------------------------------------------------------------
section "Repos (local clones)"

for spec in $( { cfg_list repos; cfg_list watch_repos; } | sed 's/:.*//' | sort -u); do
  case "$spec" in */*) ;; *) continue ;; esac
  c="$(find_clone "${spec%%/*}" "${spec#*/}")"
  if [ -z "$c" ]; then
    bad "$spec - no clone in clone-base ($(cfg_list clone_base | tr '\n' ' ' | sed 's/ $//'))"
  elif [ "$(origin_slug "$c")" != "$(printf '%s' "$spec" | tr '[:upper:]' '[:lower:]')" ]; then
    warn "$spec -> ${c/#$HOME/~} (folder name matches, but origin is $(origin_slug "$c"))"
  else
    ok "$spec -> ${c/#$HOME/~}"
  fi
done

# --- Watch mode ---------------------------------------------------------------
section "Watch mode"

if watch_enabled; then ok "watch on"; else warn "watch off$(_opt @claude-pr-review-watch-key | sed 's/^./ - prefix + & turns it on/')"; fi
if watch_running; then
  ok "poller running (pid $(cat "$STATE_DIR/watch.pid"))"
elif watch_enabled; then
  bad "watch is on but the poller isn't running - toggle watch off and on, or: $DIR/watch.sh start"
fi
if [ -f "$STATE_DIR/last-poll" ]; then
  lp="$(cat "$STATE_DIR/last-poll")"; ago=$(( ($(now) - ${lp%% *}) / 60 ))
  case "$lp" in
    *" ok") ok "last poll ${ago}m ago: ok" ;;
    *) bad "last poll ${ago}m ago failed: ${lp#* }" ;;
  esac
  if watch_enabled && [ "$ago" -gt $(( $(cfg watch_interval) / 60 + 2 )) ]; then
    warn "last poll is older than the interval - the poller may be stuck"
  fi
else
  warn "never polled"
fi
fails="$(tail -50 "$STATE_DIR/watch.log" 2>/dev/null | grep -c 'poll failed' || true)"
[ "${fails:-0}" -eq 0 ] || warn "$fails failed polls in the last 50 log lines - see ${STATE_DIR/#$HOME/~}/watch.log"
if [ -w "$STATE_DIR" ]; then ok "state dir ${STATE_DIR/#$HOME/~}"; else bad "state dir $STATE_DIR isn't writable"; fi

# --- Notifications ------------------------------------------------------------
section "Notifications"

for ch in $(cfg_list notify); do
  b="$(notify_backend "$ch")"
  if [ "$b" = "terminal-notifier" ]; then
    auth="$(terminal-notifier -diagnose 2>/dev/null | awk '/authorization/ { $1 = ""; sub(/^ +/, ""); print; exit }')"
    case "$auth" in
      authorized | provisional) ok "$ch: terminal-notifier (click: $(_or "$(_opt @claude-pr-review-notify-click)" window))" ;;
      *) warn "$ch: terminal-notifier isn't allowed to notify (${auth:-unknown}) - using osascript instead. Allow it in System Settings > Notifications, or: brew uninstall terminal-notifier" ;;
    esac
    continue
  fi
  if [ -n "$b" ]; then ok "$ch: $b"; continue; fi
  case "$ch" in
    system | macos)
      case "$(uname -s)" in
        Darwin) bad "$ch: no osascript/terminal-notifier" ;;
        *) if grep -qi microsoft /proc/version 2>/dev/null; then bad "$ch: install wsl-notify-send.exe (WSL)"
           else bad "$ch: install notify-send (libnotify)"; fi ;;
      esac ;;
    terminal) warn "$ch: no tmux client attached right now (nothing to show it on)" ;;
    cmd) bad "$ch: set @claude-pr-review-notify-cmd" ;;
    *) ;;
  esac
done

echo
if [ "$failed" -eq 0 ]; then printf '%sAll checks passed.%s\n' "$G" "$N"; else printf '%sSome checks failed (✗).%s\n' "$R" "$N"; fi
exit "$failed"
