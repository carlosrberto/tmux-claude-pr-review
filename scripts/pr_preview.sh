#!/usr/bin/env bash
#
# fzf preview of a PR: `gh pr view` with its terminal rendering (colors, and the
# body as formatted markdown). gh only renders when it thinks it writes to a
# terminal, so force that, at the preview's width. The markdown style is
# @claude-pr-review-preview-style (a glamour style: dark, light, dracula,
# tokyo-night, pink, notty).
#
#   pr_preview.sh <pr-url>
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
. "$DIR/config.sh"

style="$(_or "$(_opt @claude-pr-review-preview-style)" dark)"

GH_FORCE_TTY="${FZF_PREVIEW_COLUMNS:-100}" GLAMOUR_STYLE="$style" GH_PAGER=cat \
  gh pr view "$1" 2>&1
