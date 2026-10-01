#!/usr/bin/env bash
#
# Install (or remove) the Claude Code hooks that report review progress to
# watch mode: Stop -> "done", Notification -> "attention".
#
#   install_hooks.sh [--config-dir <dir>] [--uninstall] [--dry-run]
#
# The settings file is <dir>/settings.json, where <dir> is, in order: the
# --config-dir flag, @claude-pr-review-claude-config-dir, $CLAUDE_CONFIG_DIR,
# ~/.claude. A timestamped backup is written next to it before any change.
#
# The hook commands don't reference this plugin's path: they run
# $CLAUDE_PR_REVIEW_MARK, which open_review.sh sets only for review windows, so
# they are no-ops in every other Claude session. Re-running is idempotent.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"

config_dir=""
uninstall=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir) config_dir="${2:?--config-dir needs a path}"; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -n | --dry-run) dry_run=1; shift ;;
    -h | --help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required to edit settings.json" >&2; exit 1; }

[ -n "$config_dir" ] || config_dir="$(cfg claude_config_dir)"
config_dir="$(_expand_home "$config_dir")"
settings="$config_dir/settings.json"
[ -d "$config_dir" ] || { echo "no such Claude config dir: $config_dir" >&2; exit 1; }
[ -f "$settings" ] || echo '{}' > "$settings"

MARKER='CLAUDE_PR_REVIEW_MARK'
# shellcheck disable=SC2016  # expanded by the hook's shell, not here
stop_cmd='[ -n "$CLAUDE_PR_REVIEW_MARK" ] && "$CLAUDE_PR_REVIEW_MARK" done; true'
# shellcheck disable=SC2016
notif_cmd='[ -n "$CLAUDE_PR_REVIEW_MARK" ] && "$CLAUDE_PR_REVIEW_MARK" attention; true'

# Always strip our entries first (so install is idempotent), then re-add.
# shellcheck disable=SC2016  # jq variables, not shell ones
JQ='
  def strip($ev):
    if .hooks[$ev] then
      .hooks[$ev] |= (map(.hooks |= map(select((.command // "") | contains($marker) | not)))
                      | map(select((.hooks | length) > 0)))
      | if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end
    else . end;
  def add($ev; $cmd):
    .hooks[$ev] = ((.hooks[$ev] // []) + [{hooks: [{type: "command", command: $cmd}]}]);
  has("hooks") as $had
  | strip("Stop") | strip("Notification")
  | if $uninstall then . else add("Stop"; $stop) | add("Notification"; $notif) end
  | if ($had | not) and .hooks == {} then del(.hooks) else . end
'

new="$(jq --arg marker "$MARKER" --arg stop "$stop_cmd" --arg notif "$notif_cmd" \
  --argjson uninstall "$([ "$uninstall" -eq 1 ] && echo true || echo false)" "$JQ" "$settings")"

if [ "$new" = "$(jq . "$settings")" ]; then
  echo "$settings: already up to date"
  exit 0
fi

if [ "$dry_run" -eq 1 ]; then
  echo "would update $settings:"
  diff <(jq . "$settings") <(printf '%s\n' "$new") || true
  exit 0
fi

backup="$settings.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$settings" "$backup"
# Written in place (not mv'd over) to keep the file's mode and any symlink.
printf '%s\n' "$new" > "$settings"

echo "$([ "$uninstall" -eq 1 ] && echo removed || echo installed) review-progress hooks in $settings"
echo "backup: $backup"
