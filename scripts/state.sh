#!/usr/bin/env bash
# Sourced (after config.sh) by the watch scripts. On-disk state is the source of
# truth; the status line only reads @claude-pr-review-status, which
# render_status derives from it.
#
#   <state_dir>/
#     enabled        "on"/"off" - last toggle; wins over @claude-pr-review-watch
#     watch.pid      running poller
#     watch.lock/    mkdir lock, one poller per machine
#     last-poll      "<epoch> ok" | "<epoch> error: <message>"
#     baselined      exists once the first poll recorded already-pending PRs
#     watch.log      poller output
#     prs/<owner>__<repo>__<number>   key=value lines, one file per PR
#
# PR status: baseline | queued | reviewing | attention | done | seen | updated |
#            dismissed (hidden + never auto-reviewed until the PR stops matching)
# Several processes write PR files (poller, Claude hooks, tmux hooks, picker),
# so every write is a locked read-modify-write ending in an atomic mv.

STATE_DIR="$(cfg state_dir)"
PRS_DIR="$STATE_DIR/prs"
mkdir -p "$PRS_DIR"

now() { date +%s; }

pr_key() { printf '%s__%s__%s' "$1" "$2" "$3"; }

pr_exists() { [ -f "$PRS_DIR/$1" ]; }

# pr_get <key> <field> -> value (empty if missing).
pr_get() {
  [ -f "$PRS_DIR/$1" ] || return 0
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$PRS_DIR/$1"
}

# _lock <dir> -> 0 once acquired; steals a lock older than ~5s (crashed writer).
_lock() {
  local i=0
  until mkdir "$1" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 50 ]; then rm -rf "$1"; mkdir "$1" 2>/dev/null && return 0; return 1; fi
    sleep 0.1
  done
}

# pr_set <key> <field> <value> [<field> <value> ...] - creates the file if needed.
pr_set() {
  local key="$1" f="$PRS_DIR/$1" tmp lock="$PRS_DIR/.$1.lock"
  shift
  _lock "$lock" || return 1
  tmp="$(mktemp "$PRS_DIR/.$key.XXXXXX")"
  [ -f "$f" ] && cp "$f" "$tmp"
  set -- "$@" updated "$(now)"
  while [ $# -ge 2 ]; do
    awk -v k="$1" 'index($0, k "=") != 1' "$tmp" > "$tmp.n" && mv "$tmp.n" "$tmp"
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    shift 2
  done
  mv "$tmp" "$f"
  rmdir "$lock" 2>/dev/null || true
}

pr_rm() { rm -f "$PRS_DIR/$1"; }

# pr_keys -> every tracked PR key, one per line.
pr_keys() {
  local f
  for f in "$PRS_DIR"/*__*__*; do
    [ -f "$f" ] && printf '%s\n' "${f##*/}"
  done
  return 0
}

# window_alive <window-id> -> 0 if the tmux window still exists. (Not
# display-message -t: it exits 0 even for a window that is gone.)
window_alive() {
  [ -n "$1" ] && tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qx "$1"
}

watch_enabled() {
  local v
  v="$(cat "$STATE_DIR/enabled" 2>/dev/null || true)"
  [ -n "$v" ] || v="$(cfg watch)"
  [ "$v" = "on" ]
}

watch_running() {
  local pid
  pid="$(cat "$STATE_DIR/watch.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# config_dir_ok -> 0 if the Claude config dir review windows will use looks real.
config_dir_ok() { [ -f "$(cfg claude_config_dir)/settings.json" ]; }

# render_status - recompute @claude-pr-review-status and refresh status lines.
render_status() {
  local k s queued=0 reviewing=0 attention=0 done=0 updated=0 txt counts=""
  for k in $(pr_keys); do
    s="$(pr_get "$k" status)"
    case "$s" in
      queued)    queued=$((queued + 1)) ;;
      reviewing) reviewing=$((reviewing + 1)) ;;
      attention) attention=$((attention + 1)) ;;
      done)      done=$((done + 1)) ;;
      updated)   updated=$((updated + 1)) ;;
    esac
  done
  [ "$queued" -gt 0 ]    && counts="$counts ⧗$queued"
  [ "$reviewing" -gt 0 ] && counts="$counts ⟳$reviewing"
  [ "$done" -gt 0 ]      && counts="$counts ✓$done"
  [ "$updated" -gt 0 ]   && counts="$counts ↻$updated"
  [ "$attention" -gt 0 ] && counts="$counts ⚠$attention"

  if ! watch_enabled; then
    txt="$(cfg status_off)$counts"
  elif ! config_dir_ok || grep -q ' error' "$STATE_DIR/last-poll" 2>/dev/null; then
    txt="$(cfg status_error)$counts"
  elif [ -n "$counts" ]; then
    txt="PR$counts"
  else
    txt="$(cfg status_idle)"
  fi
  tmux set-option -gq @claude-pr-review-status "$txt" 2>/dev/null || true
  tmux refresh-client -S 2>/dev/null || true
}

# notify <message> [macos] - tmux message, plus a macOS notification when asked
# and enabled via @claude-pr-review-notify.
notify() {
  local channels
  channels=" $(cfg notify) "
  case "$channels" in
    *" tmux "*) tmux display-message "claude-pr-review: $1" 2>/dev/null || true ;;
  esac
  if [ "${2:-}" = "macos" ]; then
    case "$channels" in
      *" macos "*)
        command -v osascript >/dev/null 2>&1 &&
          osascript -e "display notification \"${1//\"/\\\"}\" with title \"Claude PR review\"" >/dev/null 2>&1 || true ;;
    esac
  fi
  return 0
}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$STATE_DIR/watch.log"; }
