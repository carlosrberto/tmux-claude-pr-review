#!/usr/bin/env bash
#
# List the open PRs watch mode should auto-review, as tab-separated records:
#
#   url <TAB> repoWithOwner <TAB> repoName <TAB> number <TAB> headSha <TAB> author <TAB> title
#
# Repos come from @claude-pr-review-watch-repos as owner/name[:filter]; repos
# without a :filter use @claude-pr-review-watch-filter. Repos are grouped by
# filter and each group is one GraphQL search per qualifier (gh search prs has no
# head SHA, which the watcher needs to notice new pushes).
#
#   all                    every open PR
#   review-requested       your review is requested directly
#   review-requested-team  ...directly or via one of your teams
#   assigned               you are an assignee
#   involves               you are involved in any way
#   mine                   review-requested OR assigned
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"

command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is not installed" >&2; exit 1; }

default_filter="$(cfg watch_filter)"

# repo_pairs -> "filter<TAB>owner/name" per watched repo. (A function: bash 3.2
# can't parse a case statement inside $(...).)
repo_pairs() {
  local spec repo filter
  cfg_list watch_repos | while IFS= read -r spec; do
    repo="${spec%%:*}"
    filter="${spec#"$repo"}"; filter="${filter#:}"
    [ -n "$filter" ] || filter="$default_filter"
    case "$repo" in
      */*) printf '%s\t%s\n' "$filter" "$repo" ;;
      *)   echo "warning: ignoring repo '$spec' - expected owner/name[:filter]" >&2 ;;
    esac
  done
}
pairs="$(repo_pairs | sort -u)"

[ -n "$pairs" ] || {
  echo "no repos to watch - set @claude-pr-review-watch-repos (or @claude-pr-review-repos)" >&2
  exit 1
}

# qualifiers <filter> -> one search qualifier per line ("" = no qualifier).
qualifiers() {
  case "$1" in
    all)                   echo "" ;;
    review-requested)      echo "user-review-requested:@me" ;;
    review-requested-team) echo "review-requested:@me" ;;
    assigned)              echo "assignee:@me" ;;
    involves)              echo "involves:@me" ;;
    mine)                  echo "user-review-requested:@me"; echo "assignee:@me" ;;
    *) echo "warning: unknown watch filter '$1' - skipping its repos" >&2; return 1 ;;
  esac
}

base="is:pr is:open archived:false"
[ "$(cfg watch_skip_drafts)" = "on" ] && base="$base draft:false"

# shellcheck disable=SC2016  # $q is a GraphQL variable, not a shell one
QUERY='query($q: String!) {
  viewer { login }
  search(query: $q, type: ISSUE, first: 100) {
    nodes { ... on PullRequest {
      url number title headRefOid
      author { login }
      repository { nameWithOwner name }
      labels(first: 30) { nodes { name } }
    } }
  }
}'
# The viewer line resolves "@me" in skip-authors; then one line per PR with
# labels as field 7 (dropped after filtering).
JQ='"@me\t" + .data.viewer.login,
  (.data.search.nodes[] | select(.url) |
    [.url, .repository.nameWithOwner, .repository.name, (.number | tostring),
     .headRefOid, (.author.login // "ghost"), ([.labels.nodes[].name] | join(",")),
     (.title | gsub("[\t\r\n]"; " "))] | @tsv)'

results=""
for filter in $(printf '%s\n' "$pairs" | cut -f1 | sort -u); do
  repo_q="$(printf '%s\n' "$pairs" | awk -F'\t' -v f="$filter" '$1 == f { printf " repo:%s", $2 }')"
  quals="$(qualifiers "$filter")" || continue
  while IFS= read -r qual; do
    out="$(gh api graphql -f query="$QUERY" -f q="$base$repo_q $qual" --jq "$JQ")"
    results="$results$out"$'\n'
  done <<EOF
$quals
EOF
done

skip_authors="$(cfg_list watch_skip_authors | tr '\n' ' ')"
skip_labels="$(cfg_list watch_skip_labels | tr '\n' ' ')"

printf '%s' "$results" | awk -F'\t' -v OFS='\t' -v sa="$skip_authors" -v sl="$skip_labels" '
  function norm(s) { s = tolower(s); sub(/^app\//, "", s); sub(/\[bot\]$/, "", s); return s }
  BEGIN {
    na = split(sa, a, " "); for (i = 1; i <= na; i++) skipA[norm(a[i])] = 1
    nl = split(sl, l, " "); for (i = 1; i <= nl; i++) skipL[tolower(l[i])] = 1
  }
  $1 == "@me" { me = norm($2); next }
  NF < 8 || seen[$1]++ { next }
  {
    au = norm($6)
    if (au in skipA || ("@me" in skipA && au == me)) next
    n = split($7, lab, ","); drop = 0
    for (i = 1; i <= n; i++) if (tolower(lab[i]) in skipL) drop = 1
    if (drop) next
    print $1, $2, $3, $4, $5, $6, $8
  }' | sort -t"$(printf '\t')" -k2,2 -k4,4n
