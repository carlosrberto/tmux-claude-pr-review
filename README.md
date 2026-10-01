# tmux-claude-pr-review

A tmux plugin that pops up a searchable list of open GitHub PRs for the repos
you care about, and — on selecting one — spins up a Claude Code **code
review** session for it: a window named `<repo>#<pr>` in your "Code Review"
session, opened in the repo's local clone, running `claude "/review <pr-url>"`.

Optionally, [watch mode](#watch-mode-auto-review) does this automatically for
PRs where your review is requested (or every PR in chosen repos), with a
status-line segment and notifications.

## How it works

- **List** — `gh search prs` for your configured repos, in an `fzf`
  popup (`display-popup`).
- **Preview** — `gh pr view` of the highlighted PR.
- **Action** — selecting a PR opens (or re-focuses) a review window and launches
  Claude with your review command.
- **Watch** — a background poller opens review windows for new matching PRs;
  Claude Code hooks report back when each review is done.

## Requirements

- `tmux` 3.2+ (needs `display-popup`)
- [`fzf`](https://github.com/junegunn/fzf)
- [`gh`](https://cli.github.com/), authenticated (`gh auth login`)
- `claude` (Claude Code) on `PATH`
- [`jq`](https://jqlang.org/) — only for `install_hooks.sh` (watch mode)

## Install

### With [TPM](https://github.com/tmux-plugins/tpm)

```tmux
set -g @plugin 'carlosrberto/tmux-claude-pr-review'
```

Then `prefix + I`.

### Manual

```tmux
run-shell /path/to/tmux-claude-pr-review/claude_pr_review.tmux
```

## Configure

Everything is set through tmux user options in `~/.tmux.conf`:

```tmux
# Repos to list PRs for (owner/name) — ONLY these are shown. Space/comma list.
set -g @claude-pr-review-repos      'your-org/web-app your-org/api'

# Which PRs, within those repos:
#   all | involves | review-requested | author | assigned   (default: all)
set -g @claude-pr-review-filter     'all'

set -g @claude-pr-review-limit      '50'           # max PRs fetched
set -g @claude-pr-review-clone-base '~/projects'   # where local clones live (list, searched in order)
set -g @claude-pr-review-session    'Code Review'  # tmux session for reviews
set -g @claude-pr-review-cmd        '/review'      # slash command (PR url appended)
```

`@claude-pr-review-repos` is required; the rest have the defaults shown. Reload
with `tmux source-file ~/.tmux.conf` after changing them.

> **Tip on `filter`.** `all` shows every open PR in the listed repos (including
> bot PRs like dependabot). For a focused review queue, `review-requested`
> (awaiting your review) or `involves` (PRs you're part of) is usually better.

## Usage

Press **`prefix + R`** to open the picker.

| Key      | Action                                             |
| -------- | -------------------------------------------------- |
| `enter`  | Open / focus the review session for it             |
| `ctrl-r` | Re-review: replace its window with a fresh review  |
| `ctrl-o` | Open the PR on GitHub (popup stays open)           |
| `esc`    | Close the popup                                    |
| (type)   | Fuzzy-filter the list                              |

Each PR is prefixed with its [watch mode](#watch-mode-auto-review) status:
`⟳` reviewing, `✓` done, `↻` new pushes since the review, `⚠` needs you,
`⧗` queued, `○` pending (not auto-reviewed), `·` seen.

On `enter`:

1. The **`Code Review`** session is created if missing.
2. A window **`<repo-name>#<pr-number>`** (e.g. `web-app#229`) is created
   if missing, in the repo's local clone, else `$HOME`. Each `clone_base` folder
   is searched in order, up to 3 levels deep; a dir whose `origin` remote is the
   PR's `owner/repo` wins over one that only has the repo's name.
3. That window runs `claude "/review <pr-url>"`.
4. Re-selecting the same PR just focuses its window — Claude is not relaunched.

## Watch mode (auto-review)

Watch mode polls GitHub in the background and, for each new PR that matches,
opens a review window exactly as if you had picked it (`<repo>#<pr>` in the
"Code Review" session, running your review command). A status-line segment
shows what's going on, and you get a tmux message plus a macOS notification
when a review is ready.

### Setup

```tmux
set -g @claude-pr-review-watch-key         'W'               # prefix + W toggles (no default)
set -g @claude-pr-review-claude-config-dir '~/.claude-work'  # CLAUDE_CONFIG_DIR for review windows
set -g status-right '#{claude_pr_review_status} | %H:%M'     # the status segment
```

Then install the Claude Code hooks that report review progress (once):

```sh
~/.tmux/plugins/tmux-claude-pr-review/scripts/install_hooks.sh --dry-run   # show the change
~/.tmux/plugins/tmux-claude-pr-review/scripts/install_hooks.sh             # apply (backs up first)
```

They go in `<config-dir>/settings.json` (`--config-dir`, else
`@claude-pr-review-claude-config-dir`, else `$CLAUDE_CONFIG_DIR`, else
`~/.claude`) and are no-ops outside review windows. `--uninstall` removes them.

> **Set `@claude-pr-review-claude-config-dir` if you use a non-default Claude
> config dir.** The poller runs from tmux, which usually doesn't see a
> `CLAUDE_CONFIG_DIR` your shell rc sets — without the option, review windows
> could silently use `~/.claude` (missing your plugins and these hooks). The
> watcher refuses to start if that dir has no `settings.json`.

### What gets reviewed

```tmux
# owner/name[:filter] — defaults to @claude-pr-review-repos
set -g @claude-pr-review-watch-repos  'your-org/web-app:all your-org/api'
set -g @claude-pr-review-watch-filter 'mine'   # for repos without a :filter
```

| Filter                  | Auto-reviews                                  |
| ----------------------- | --------------------------------------------- |
| `mine` (default)        | your review is requested directly, OR you're an assignee |
| `review-requested`      | your review is requested directly             |
| `review-requested-team` | ...directly or via one of your teams (broad with CODEOWNERS) |
| `assigned`              | you're an assignee                            |
| `involves`              | you're involved in any way                    |
| `all`                   | every open PR                                 |

```tmux
set -g @claude-pr-review-watch-skip-drafts  'on'
set -g @claude-pr-review-watch-skip-authors '@me dependabot renovate'  # app bots: bare login
set -g @claude-pr-review-watch-skip-labels  ''
```

### Behaviour

- **Baseline.** PRs already waiting when watch is turned on (including ones
  that arrived while it was off) are recorded as pending (`○`), not reviewed —
  no burst of windows. A message says how many; they're listed in the
  tracked-PR popup, where `enter` starts a review. A tmux restart with watch on
  doesn't re-baseline, so PRs that arrived while tmux was down are reviewed.
- **At most `@claude-pr-review-watch-max` (2) reviews at once**; the rest wait
  as queued and start as soon as a review finishes.
- **New pushes** to a reviewed PR mark it `↻` — never re-reviewed
  automatically. Re-review from the picker with `ctrl-r`.
- **Seen.** A finished review counts as unseen (`✓`) until you look at its
  window (or close it).
- Merged/closed PRs, or ones no longer requested, are forgotten once their
  window is closed.
- The toggle is persisted, so it survives a tmux restart.

### Tracked-PR popup

```tmux
set -g @claude-pr-review-status-key 'P'   # prefix + P (no default)
```

Lists the PRs watch mode tracks, most urgent first (`⚠ ✓ ⟳ ↻ ⧗ ○ ·`), including
pending ones (`○`) it didn't auto-review. The
preview is a live capture of the PR's review window, so you can read Claude's
verdict without switching (`gh pr view` when it has no window). The header
shows watch on/off and the last poll result, which explains a `PR ✗`.

| Key      | Action                                    |
| -------- | ----------------------------------------- |
| `enter`  | Jump to the review window (or start a review) |
| `ctrl-r` | Re-review in a fresh window               |
| `ctrl-o` | Open the PR on GitHub (popup stays open)  |
| `ctrl-x` | Dismiss: close its window, remove its worktree, hide it (never auto-reviewed while it stays open) |
| `ctrl-d` | Clean up every reviewed PR (asks first)   |

`ctrl-d` closes the review windows and removes the review worktrees (and their
branches) of every PR whose review finished (`✓`, `·`, `↻`). It's local only, so
no GitHub calls and no poll. The PRs stay tracked, so the next poll doesn't
re-review them. Worktrees are found at `<clone>/.claude/worktrees/pr-review-<n>`
(the `uux-dev` `pr-review` layout; override with `@claude-pr-review-worktree`,
using `{number}`), and only ones git lists as worktrees of that clone are
removed. The same cleanup is `scripts/cleanup.sh [--dry-run] [<pr-key>]`.

### Status segment

| Shows        | Means                                         |
| ------------ | --------------------------------------------- |
| `PR ⏸`       | watch off (counts still shown if any)         |
| `PR 👁`      | on, nothing pending                           |
| `PR ⧗1 ⟳2 ✓3 ↻1 ⚠1` | queued, reviewing, done-unseen, new pushes, needs you |
| `PR ✗`       | last poll failed (e.g. `gh` auth) or bad config dir |

The segment reads a tmux option the watcher keeps current
(`#{@claude-pr-review-status}`), so no script runs on status refresh.

### Other options

```tmux
set -g @claude-pr-review-watch          'off'   # initial state before the first toggle
set -g @claude-pr-review-watch-interval '300'   # seconds between polls
set -g @claude-pr-review-watch-max      '2'
set -g @claude-pr-review-notify         'tmux macos'
set -g @claude-pr-review-status-off     'PR ⏸'
set -g @claude-pr-review-status-idle    'PR 👁'
set -g @claude-pr-review-status-error   'PR ✗'
set -g @claude-pr-review-state-dir      ''      # default: $XDG_STATE_HOME/tmux-claude-pr-review
set -g @claude-pr-review-worktree       '.claude/worktrees/pr-review-{number}'  # under the clone, for cleanup
```

### Inspecting

```sh
scripts/watch.sh status   # on/off, poller pid, last poll, tracked PRs
scripts/watch.sh poll     # one poll now, in the foreground
tail -f ~/.local/state/tmux-claude-pr-review/watch.log
```

## Scripting / automation

`scripts/open_review.sh` is the public entry point for the "launch a review"
action — the picker calls it, and you can call it directly from your own scripts.

```sh
# Open a review and switch to it (default):
scripts/open_review.sh https://github.com/your-org/web-app/pull/229

# Create the session/window + launch Claude, but DON'T switch to it
# (stays out of your way; also works with no client attached, e.g. from cron):
scripts/open_review.sh --background https://github.com/your-org/web-app/pull/229

# Accepts a URL, "owner/repo <number>", or "owner/repo#number":
scripts/open_review.sh -b your-org/web-app 229
scripts/open_review.sh -b your-org/web-app#229

# For scripting: print the pane id instead of "<session>:<window>":
scripts/open_review.sh -b --print-pane <pr>

# Re-review: kill the PR's existing window and launch a fresh review:
scripts/open_review.sh --replace <pr>

# Preview what it would do without touching tmux:
scripts/open_review.sh --dry-run <pr>
```

Behaviour:

- Idempotent — re-running for the same PR just refocuses its window; Claude is
  not relaunched.
- `--background` only suppresses switching your client to the review session
  (it does _not_ open/raise the tmux window); the window and Claude are still
  created. Without it, your client switches to the review session.
- Prints `<session>:<window>` on success (or the pane id with `--print-pane`),
  so an automation can target the window afterwards.

## Appearance / key options (tmux)

```tmux
set -g @claude-pr-review-key           'R'    # prefix key (default: R)
set -g @claude-pr-review-width         '60%'  # popup width
set -g @claude-pr-review-height        '85%'  # popup height
set -g @claude-pr-review-preview-width '60%'  # preview share of the popup
```

## Layout

```
claude_pr_review.tmux        # plugin entry (sourced/executed by TPM)
scripts/
  config.sh                  # reads @claude-pr-review-* tmux options (sourced)
  state.sh                   # watch-mode state files + status rendering (sourced)
  list_prs.sh                # gh query -> one TSV line per PR
  picker.sh                  # fzf popup + gh pr view preview
  open_review.sh             # ensure session/window + launch claude "/review"
  watch_list.sh              # GraphQL query -> PRs watch mode should review
  watch.sh                   # poller: start/stop/toggle/status/poll/dispatch
  status_picker.sh           # prefix + P popup of tracked PRs
  status_preview.sh          # its preview: live review window capture
  cleanup.sh                 # close windows + remove worktrees of finished reviews
  mark.sh                    # review progress from Claude + tmux hooks
  install_hooks.sh           # add/remove the Claude Code hooks
```
