#!/usr/bin/env bash
#
# List open PRs for the configured repos as tab-separated records:
#
#   url <TAB> repoWithOwner <TAB> repoName <TAB> number <TAB> title <TAB> author
#
# Only the repos listed in `repos` are queried (one `gh search prs` call with a
# --repo flag per repo). The `filter` config key maps to a gh "@me" qualifier.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"

command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is not installed" >&2; exit 1; }

filter="$(cfg filter)"; [ -n "$filter" ] || filter="all"
limit="$(cfg limit)"; [ -n "$limit" ] || limit="50"

# Explicit repo allow-list (repeated lines and/or comma/space separated).
repo_flags=""
count=0
while IFS= read -r r; do
  [ -n "$r" ] || continue
  case "$r" in
    */*) repo_flags="$repo_flags --repo=$r"; count=$((count + 1)) ;;
    *)   echo "warning: ignoring repo '$r' — expected owner/name" >&2 ;;
  esac
done <<EOF
$(cfg_list repos)
EOF

if [ "$count" -eq 0 ]; then
  echo "no repos configured — set @claude-pr-review-repos 'owner/name ...' in tmux.conf" >&2
  exit 1
fi

# filter -> gh qualifier (single token, safe unquoted)
case "$filter" in
  all)              ff="" ;;
  involves)         ff="--involves=@me" ;;
  review-requested) ff="--review-requested=@me" ;;
  author)           ff="--author=@me" ;;
  assigned)         ff="--assignee=@me" ;;
  *)                ff="" ;;
esac

JQ='.[] | [.url, .repository.nameWithOwner, .repository.name, (.number|tostring), .title, .author.login] | @tsv'
TAB="$(printf '\t')"

# shellcheck disable=SC2086
gh search prs $repo_flags --state=open --limit="$limit" $ff \
  --json number,title,url,author,repository --jq "$JQ" \
  | awk -F"$TAB" '!seen[$1]++' | sort -t"$TAB" -k2,2 -k4,4nr
