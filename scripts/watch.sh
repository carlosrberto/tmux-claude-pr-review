#!/usr/bin/env bash
#
# Watch mode: poll for PRs to auto-review and open a Claude review window for
# each new one (at most @claude-pr-review-watch-max at a time).
#
#   watch.sh start      (re)start the poller in the background if watch is on
#   watch.sh stop       stop the poller
#   watch.sh toggle     flip watch on/off (persisted), start/stop accordingly
#   watch.sh status     print the watcher state and tracked PRs
#   watch.sh poll       run one poll now, in the foreground
#   watch.sh dispatch   open queued reviews if slots are free (no network)
#   watch.sh loop       the poller itself (what start runs)
#
# PRs already waiting when watch is first enabled (or toggled back on) are
# recorded as "baseline" and not auto-reviewed; a notification says how many,
# and the status popup lists them (○) to start by hand. A new push to a
# reviewed PR marks it "updated"; it is never re-reviewed automatically.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"
# shellcheck source=scripts/state.sh
. "$DIR/state.sh"

TAB="$(printf '\t')"

# --- poll -------------------------------------------------------------------

poll() {
  local list err records key st old_sha url repo name number sha author title
  if ! config_dir_ok; then
    printf '%s error: no settings.json in %s\n' "$(now)" "$(cfg claude_config_dir)" > "$STATE_DIR/last-poll"
    log "poll skipped: no settings.json in $(cfg claude_config_dir)"
    render_status
    return 1
  fi

  err="$(mktemp "$STATE_DIR/.err.XXXXXX")"
  if ! list="$("$DIR/watch_list.sh" 2>"$err")"; then
    printf '%s error: %s\n' "$(now)" "$(grep -v '^warning' "$err" | head -1)" > "$STATE_DIR/last-poll"
    log "poll failed: $(tr '\n' ' ' < "$err")"
    rm -f "$err"
    render_status
    return 1
  fi
  grep '^warning' "$err" | while IFS= read -r w; do log "$w"; done
  rm -f "$err"
  printf '%s ok\n' "$(now)" > "$STATE_DIR/last-poll"

  records=""
  while IFS="$TAB" read -r url repo name number sha author title; do
    [ -n "$url" ] || continue
    key="$(pr_key "${repo%%/*}" "$name" "$number")"
    records="$records $key "

    if [ ! -f "$STATE_DIR/baselined" ]; then
      pr_exists "$key" || pr_set "$key" url "$url" repo "$repo" number "$number" \
        title "$title" author "$author" head_sha "$sha" status baseline
      continue
    fi

    if ! pr_exists "$key"; then
      pr_set "$key" url "$url" repo "$repo" number "$number" title "$title" \
        author "$author" head_sha "$sha" status queued queued_at "$(now)"
      log "queued $name#$number ($title)"
      continue
    fi

    st="$(pr_get "$key" status)"
    old_sha="$(pr_get "$key" head_sha)"
    if [ "$sha" != "$old_sha" ]; then
      case "$st" in
        done | seen) pr_set "$key" status updated head_sha "$sha" title "$title"
                     log "updated $name#$number (new push)" ;;
        *)           pr_set "$key" head_sha "$sha" title "$title" ;;
      esac
    fi
  done <<EOF
$list
EOF

  if [ ! -f "$STATE_DIR/baselined" ]; then
    touch "$STATE_DIR/baselined"
    report_baseline
  fi

  reconcile "$records"
  dispatch
}

# report_baseline - say how many pending PRs were left for you to start by hand.
report_baseline() {
  local key n=0 where status_key
  for key in $(pr_keys); do
    [ "$(pr_get "$key" status)" = "baseline" ] && n=$((n + 1))
  done
  log "baseline: $n pending PRs not auto-reviewed"
  [ "$n" -gt 0 ] || return 0
  status_key="$(_opt @claude-pr-review-status-key)"
  where="${status_key:+ - prefix + $status_key to see}"
  notify "$n pending PR$([ "$n" -eq 1 ] || echo s) not auto-reviewed$where"
}

# reconcile "<space-separated keys still matching>" - forget PRs that no longer
# match (merged, closed, request removed) unless their window is still open, and
# treat a closed review window as seen.
reconcile() {
  local key st window
  for key in $(pr_keys); do
    st="$(pr_get "$key" status)"
    window="$(pr_get "$key" window)"
    if window_alive "$window"; then continue; fi
    case "$1" in
      *" $key "*) ;;
      *) pr_rm "$key"; log "forgot $key"; continue ;;
    esac
    case "$st" in
      reviewing | attention | done) pr_set "$key" status seen ;;
    esac
  done
}

# --- dispatch ----------------------------------------------------------------

dispatch() {
  local lock="$STATE_DIR/.dispatch.lock" max active=0 key st queued url label title
  watch_enabled || return 0
  _lock "$lock" || return 0

  max="$(cfg watch_max)"
  for key in $(pr_keys); do
    st="$(pr_get "$key" status)"
    case "$st" in
      reviewing | attention) window_alive "$(pr_get "$key" window)" && active=$((active + 1)) ;;
    esac
  done

  # Oldest queued first.
  queued="$(for key in $(pr_keys); do
    [ "$(pr_get "$key" status)" = "queued" ] && printf '%s %s\n' "$(pr_get "$key" queued_at)" "$key"
  done | sort -n | cut -d' ' -f2)"

  for key in $queued; do
    [ "$active" -lt "$max" ] || break
    url="$(pr_get "$key" url)"
    title="$(pr_get "$key" title)"
    label="$(pr_get "$key" repo)#$(pr_get "$key" number)"; label="${label#*/}"
    if "$DIR/open_review.sh" --background "$url" >/dev/null 2>>"$STATE_DIR/watch.log"; then
      pr_set "$key" reviewed_sha "$(pr_get "$key" head_sha)"
      active=$((active + 1))
      log "reviewing $label"
      notify "🔍 reviewing $label${title:+ - $title}"
    else
      pr_set "$key" status seen
      log "failed to open a review for $label - skipped"
    fi
  done

  rmdir "$lock" 2>/dev/null || true
  render_status
}

# --- poller lifecycle ---------------------------------------------------------

loop() {
  local lock="$STATE_DIR/watch.lock" interval sleeper=""
  if ! mkdir "$lock" 2>/dev/null; then
    if watch_running; then log "loop: already running"; exit 0; fi
    rm -rf "$lock"; mkdir "$lock" || exit 1
  fi
  echo $$ > "$STATE_DIR/watch.pid"
  # shellcheck disable=SC2064  # expand $lock now
  trap "[ -n \"\$sleeper\" ] && kill \$sleeper 2>/dev/null; rm -rf '$lock' '$STATE_DIR/watch.pid'" EXIT
  trap 'exit 0' TERM INT HUP
  log "watch started (pid $$)"

  local fails=0 delay
  while tmux list-sessions >/dev/null 2>&1 && watch_enabled; do
    interval="$(cfg watch_interval)"
    case "$interval" in '' | *[!0-9]*) interval=300 ;; esac
    if poll; then
      [ "$fails" -eq 0 ] || log "poll ok again after $fails failed"
      fails=0; delay="$interval"
    else
      # Back off from 30s (30, 60, 120, ...) up to the normal interval, so the
      # watch catches up soon after the network returns (e.g. after a wake).
      fails=$((fails + 1))
      delay=$((30 << (fails > 5 ? 5 : fails - 1)))
      [ "$delay" -le "$interval" ] || delay="$interval"
      log "retrying in ${delay}s"
    fi
    rotate_log
    wait_until $(( $(now) + delay ))
  done
  log "watch stopped"
}

# wait_until <epoch> - sleep until a wall-clock time, in short steps. A plain
# `sleep N` stops counting while the machine sleeps, so a poll due during
# standby would run up to N seconds after waking; checking the wall clock makes
# it run within one step of waking.
wait_until() {
  local step=15 t before
  while :; do
    t=$(( $1 - $(now) ))
    [ "$t" -gt 0 ] || return 0
    [ "$t" -le "$step" ] || t="$step"
    before="$(now)"
    sleep "$t" & sleeper=$!
    wait "$sleeper"; sleeper=""
    [ $(( $(now) - before )) -le $(( t + 60 )) ] || log "resumed after $(( ($(now) - before) / 60 ))m asleep"
  done
}

rotate_log() {
  local f="$STATE_DIR/watch.log"
  [ -f "$f" ] || return 0
  if [ "$(wc -c < "$f")" -gt 524288 ]; then
    tail -n 1000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
}

stop() {
  local pid i=0
  pid="$(cat "$STATE_DIR/watch.pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
  fi
  rm -rf "$STATE_DIR/watch.lock" "$STATE_DIR/watch.pid"
}

# start - restart semantics, so a tmux.conf reload picks up new code and config.
start() {
  stop
  if watch_enabled; then
    if ! config_dir_ok; then
      notify "watch not started: no settings.json in $(cfg claude_config_dir) - set @claude-pr-review-claude-config-dir" macos
      log "start refused: no settings.json in $(cfg claude_config_dir)"
    else
      nohup "$DIR/watch.sh" loop >>"$STATE_DIR/watch.log" 2>&1 </dev/null &
    fi
  fi
  render_status
}

toggle() {
  if watch_enabled; then
    echo off > "$STATE_DIR/enabled"
    stop
    notify "watch off"
  else
    echo on > "$STATE_DIR/enabled"
    # PRs already pending now are recorded, not reviewed in a burst.
    rm -f "$STATE_DIR/baselined"
    start
    config_dir_ok && notify "watch on"
  fi
  render_status
}

status() {
  local key
  printf 'watch:      %s\n' "$(watch_enabled && echo on || echo off)"
  printf 'poller:     %s\n' "$(watch_running && echo "running (pid $(cat "$STATE_DIR/watch.pid"))" || echo stopped)"
  printf 'last poll:  %s\n' "$(cat "$STATE_DIR/last-poll" 2>/dev/null || echo never)"
  printf 'config dir: %s%s\n' "$(cfg claude_config_dir)" "$(config_dir_ok || echo '  (no settings.json!)')"
  printf 'state dir:  %s\n' "$STATE_DIR"
  printf 'status:     %s\n\n' "$(tmux show-option -gqv @claude-pr-review-status)"
  for key in $(pr_keys); do
    printf '%-10s %s\n' "$(pr_get "$key" status)" "$(pr_get "$key" url)"
  done
}

case "${1:-}" in
  start)    start ;;
  stop)     stop; render_status ;;
  toggle)   toggle ;;
  status)   status ;;
  poll)     poll; render_status ;;
  dispatch) dispatch ;;
  loop)     loop ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
