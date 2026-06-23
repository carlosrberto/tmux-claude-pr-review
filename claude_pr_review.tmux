#!/usr/bin/env bash
#
# Plugin entry point, sourced by TPM (Tmux Plugin Manager) at tmux start.
# Binds a key (default: prefix + R) that opens a popup listing open PRs for the
# configured repos; selecting one opens a Claude review session.
#
# The plugin version lives in the top-level VERSION file.
#
# Configure with:  set -g @claude-pr-review-key 'R'
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEY="$(tmux show-option -gqv @claude-pr-review-key)"
[ -n "$KEY" ] || KEY="R"

POPUP_W="$(tmux show-option -gqv @claude-pr-review-width)"
[ -n "$POPUP_W" ] || POPUP_W="90%"

POPUP_H="$(tmux show-option -gqv @claude-pr-review-height)"
[ -n "$POPUP_H" ] || POPUP_H="85%"

tmux bind-key "$KEY" display-popup -E -w "$POPUP_W" -h "$POPUP_H" "$CURRENT_DIR/scripts/picker.sh"
