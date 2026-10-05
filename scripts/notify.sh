#!/usr/bin/env bash
# Sourced by state.sh. Notifications, over the channels in
# @claude-pr-review-notify (default "tmux system"):
#
#   tmux      tmux display-message (status line) - every event
#   system    the OS's notifications - alerts only:
#               macOS   terminal-notifier, else osascript. With terminal-notifier
#                       a click goes to the review window (switches your tmux
#                       client to it and brings the terminal app forward), or
#                       opens the PR on GitHub: @claude-pr-review-notify-click
#                       window (default) | github
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
  local msg="$1" url="$2" key="${3:-}"
  case "$(notify_backend system)" in
    terminal-notifier)
      CLICK_ARGS=()
      _click_args "$url" "$key"
      # Unsigned builds may not be allowed to notify (macOS 26 refuses them with
      # "Notifications are not allowed"); fall back to osascript when it fails.
      { terminal-notifier -title "$NOTIFY_TITLE" -message "$msg" \
          -group "${key:-claude-pr-review}" ${CLICK_ARGS[@]+"${CLICK_ARGS[@]}"} >/dev/null 2>&1 ||
          _osascript_notify "$msg"; } & ;;
    osascript) _osascript_notify "$msg" & ;;
    wsl-notify-send.exe)
      wsl-notify-send.exe --appId "$NOTIFY_TITLE" -c "$NOTIFY_TITLE" "$msg" >/dev/null 2>&1 & ;;
    notify-send)
      notify-send -a "$NOTIFY_TITLE" "$NOTIFY_TITLE" "$msg" >/dev/null 2>&1 & ;;
  esac
}

# _click_args <url> <pr-key> - fill CLICK_ARGS with terminal-notifier's click
# options. "window": switch the first attached tmux client to the PR's review
# window and activate the terminal app; "github" (or no live window): open the PR.
_click_args() {
  local url="$1" key="$2" window="" tty sock tmux_bin app
  [ -z "$key" ] || window="$(pr_get "$key" window)"
  if [ "$(_or "$(_opt @claude-pr-review-notify-click)" window)" = "window" ] && window_alive "$window"; then
    tty="$(_client_ttys | head -1)"
    sock="$(tmux display-message -p '#{socket_path}' 2>/dev/null)"
    tmux_bin="$(command -v tmux)"
    if [ -n "$tty" ] && [ -n "$sock" ]; then
      # -execute runs through sh, so the command is a quoted string.
      CLICK_ARGS=(-execute "$(_sq "$tmux_bin") -S $(_sq "$sock") switch-client -c $(_sq "$tty") -t $(_sq "$window")")
      app="$(_terminal_app)"
      [ -z "$app" ] || CLICK_ARGS+=(-activate "$app")
      return 0
    fi
  fi
  [ -z "$url" ] || CLICK_ARGS=(-open "$url")
}

# _terminal_app -> the macOS bundle id of the terminal tmux runs in
# (@claude-pr-review-notify-app overrides), or empty.
_terminal_app() {
  local app
  app="$(_opt @claude-pr-review-notify-app)"
  [ -z "$app" ] || { printf '%s' "$app"; return 0; }
  case "$(tmux show-environment -g TERM_PROGRAM 2>/dev/null | sed 's/^TERM_PROGRAM=//')" in
    ghostty)        echo com.mitchellh.ghostty ;;
    iTerm.app)      echo com.googlecode.iterm2 ;;
    Apple_Terminal) echo com.apple.Terminal ;;
    WezTerm)        echo com.github.wez.wezterm ;;
    kitty)          echo net.kovidgoyal.kitty ;;
    Alacritty)      echo org.alacritty ;;
  esac
}

# _sq <word> -> single-quoted for sh.
_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

_osascript_notify() {
  osascript -e "display notification \"$(_esc_dq "$1")\" with title \"$NOTIFY_TITLE\"" >/dev/null 2>&1
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
