#!/usr/bin/env bash
# Sourced by state.sh. Notifications, over the channels in
# @claude-pr-review-notify (default "tmux system"):
#
#   tmux      tmux display-message (status line) - every event
#   system    the OS's notifications - alerts only:
#               macOS   terminal-notifier (click opens the PR), else osascript
#               Linux   notify-send
#               WSL     wsl-notify-send.exe
#   terminal  a desktop notification escape sequence (OSC 777, or OSC 9) written
#             to each attached client's terminal - alerts only. Shown by Ghostty,
#             iTerm2, WezTerm, kitty, foot...; works over SSH, needs no
#             allow-passthrough (it goes to the client tty, not through a pane)
#   cmd       @claude-pr-review-notify-cmd, run by sh in the background - every
#             event - with PR_EVENT PR_MESSAGE PR_URL PR_LABEL PR_TITLE set
#
# "macos" is an alias of "system". Events: done, attention, error (alerts);
# reviewing, baseline, watch (info). A channel whose tool is missing is skipped
# quietly; doctor.sh reports which channels can work here.

# notify <event> <message> [pr-key]
notify() {
  local event="$1" msg="$2" key="${3:-}" url="" label="" title="" alert=0 ch
  case "$event" in done | attention | error) alert=1 ;; esac
  if [ -n "$key" ] && pr_exists "$key"; then
    url="$(pr_get "$key" url)"; title="$(pr_get "$key" title)"
    label="$(pr_get "$key" repo)#$(pr_get "$key" number)"; label="${label#*/}"
  fi
  for ch in $(cfg_list notify); do
    case "$ch" in
      tmux) tmux display-message "claude-pr-review: $msg" 2>/dev/null || true ;;
      system | macos) [ "$alert" -eq 0 ] || _notify_system "$msg" "$url" "$key" ;;
      terminal) [ "$alert" -eq 0 ] || _notify_terminal "$msg" ;;
      cmd) _notify_cmd "$event" "$msg" "$url" "$label" "$title" ;;
    esac
  done
  return 0
}

NOTIFY_TITLE="Claude PR review"

# notify_backend <channel> -> the tool a channel would use here ("" = none).
notify_backend() {
  case "$1" in
    tmux) echo "tmux display-message" ;;
    system | macos)
      if command -v terminal-notifier >/dev/null 2>&1; then echo terminal-notifier
      elif command -v osascript >/dev/null 2>&1; then echo osascript
      elif command -v wsl-notify-send.exe >/dev/null 2>&1; then echo wsl-notify-send.exe
      elif command -v notify-send >/dev/null 2>&1; then echo notify-send
      fi ;;
    terminal) [ -n "$(_client_ttys)" ] && echo "OSC $(_osc_kind) to attached clients" ;;
    cmd) [ -n "$(cfg notify_cmd)" ] && echo "sh -c @claude-pr-review-notify-cmd" ;;
  esac
}

_notify_system() {
  local msg="$1" url="$2" group="${3:-claude-pr-review}"
  case "$(notify_backend system)" in
    terminal-notifier)
      terminal-notifier -title "$NOTIFY_TITLE" -message "$msg" -group "$group" \
        ${url:+-open "$url"} >/dev/null 2>&1 & ;;
    osascript)
      osascript -e "display notification \"$(_esc_dq "$msg")\" with title \"$NOTIFY_TITLE\"" >/dev/null 2>&1 & ;;
    wsl-notify-send.exe)
      wsl-notify-send.exe --appId "$NOTIFY_TITLE" -c "$NOTIFY_TITLE" "$msg" >/dev/null 2>&1 & ;;
    notify-send)
      notify-send -a "$NOTIFY_TITLE" "$NOTIFY_TITLE" "$msg" >/dev/null 2>&1 & ;;
  esac
}

_esc_dq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# _client_ttys -> the tty of every attached tmux client.
_client_ttys() { tmux list-clients -F '#{client_tty}' 2>/dev/null; }

# _osc_kind -> 777 (title + body) for terminals known to show it, else 9 (body
# only, the most widely supported).
_osc_kind() {
  case "$(tmux list-clients -F '#{client_termtype} #{client_termname}' 2>/dev/null | head -1)" in
    *[Gg]hostty* | *[Ww]ez[Tt]erm* | *foot* | *rxvt* | *konsole*) echo 777 ;;
    *) echo 9 ;;
  esac
}

_notify_terminal() {
  local msg tty kind
  # Strip control characters (and ";", the OSC 777 field separator).
  msg="$(printf '%s' "$1" | tr -d '\000-\037\177' | tr ';' ',')"
  kind="$(_osc_kind)"
  for tty in $(_client_ttys); do
    [ -w "$tty" ] || continue
    if [ "$kind" = 777 ]; then
      printf '\033]777;notify;%s;%s\007' "$NOTIFY_TITLE" "$msg" > "$tty" 2>/dev/null || true
    else
      printf '\033]9;%s\007' "$NOTIFY_TITLE: $msg" > "$tty" 2>/dev/null || true
    fi
  done
}

_notify_cmd() {
  local cmd
  cmd="$(cfg notify_cmd)"
  [ -n "$cmd" ] || return 0
  PR_EVENT="$1" PR_MESSAGE="$2" PR_URL="$3" PR_LABEL="$4" PR_TITLE="$5" \
    sh -c "$cmd" >>"$STATE_DIR/watch.log" 2>&1 </dev/null &
}
