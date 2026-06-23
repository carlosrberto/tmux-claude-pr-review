#!/usr/bin/env bash
#
# List open PRs for the configured orgs/repos as tab-separated records:
#
#   url <TAB> repoWithOwner <TAB> repoName <TAB> number <TAB> title <TAB> author
#
# Orgs and repos are queried separately with `gh search prs` and merged (deduped
# by URL). The `filter` config key maps to a gh "@me" qualifier.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"

[ -f "$CONFIG" ] || { echo "no config found at $CONFIG — copy config.example there" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is not installed" >&2; exit 1; }

orgs="$(cfg orgs)"
repos="$(cfg repos)"
filter="$(cfg filter)"; [ -n "$filter" ] || filter="all"
limit="$(cfg limit)"; [ -n "$limit" ] || limit="50"

if [ -z "$orgs" ] && [ -z "$repos" ]; then
  echo "config has no 'orgs' or 'repos' set ($CONFIG)" >&2
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

# Build repeated --owner / --repo flags from the comma/space lists.
owner_flags=""
for o in $(printf '%s' "$orgs" | tr ',' ' '); do owner_flags="$owner_flags --owner=$o"; done
repo_flags=""
for r in $(printf '%s' "$repos" | tr ',' ' '); do repo_flags="$repo_flags --repo=$r"; done

JQ='.[] | [.url, .repository.nameWithOwner, .repository.name, (.number|tostring), .title, .author.login] | @tsv'
TAB="$(printf '\t')"

{
  if [ -n "$owner_flags" ]; then
    # shellcheck disable=SC2086
    gh search prs $owner_flags --state=open --limit="$limit" $ff \
      --json number,title,url,author,repository --jq "$JQ"
  fi
  if [ -n "$repo_flags" ]; then
    # shellcheck disable=SC2086
    gh search prs $repo_flags --state=open --limit="$limit" $ff \
      --json number,title,url,author,repository --jq "$JQ"
  fi
} | awk -F"$TAB" '!seen[$1]++' | sort -t"$TAB" -k2,2 -k4,4nr
