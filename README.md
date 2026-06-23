# tmux-claude-pr-review

A tmux plugin that pops up a searchable list of open GitHub PRs for the orgs and
repos you care about, and — on selecting one — spins up a Claude Code **code
review** session for it: a window named `<repo>#<pr>` in your "Code Review"
session, opened in the repo's local clone, running `claude "/review <pr-url>"`.

## How it works

- **List** — `gh search prs` for your configured orgs and repos, in an `fzf`
  popup (`display-popup`).
- **Preview** — `gh pr view` of the highlighted PR.
- **Action** — selecting a PR opens (or re-focuses) a review window and launches
  Claude with your review command.

## Requirements

- `tmux` 3.2+ (needs `display-popup`)
- [`fzf`](https://github.com/junegunn/fzf)
- [`gh`](https://cli.github.com/), authenticated (`gh auth login`)
- `claude` (Claude Code) on `PATH`

## Install

### With [TPM](https://github.com/tmux-plugins/tpm)

```tmux
set -g @plugin 'youruser/tmux-claude-pr-review'
```

Then `prefix + I`.

### Manual

```tmux
run-shell /path/to/tmux-claude-pr-review/claude_pr_review.tmux
```

## Configure

Copy the sample config and edit it:

```sh
mkdir -p ~/.config/tmux-claude-pr-review
cp config.example ~/.config/tmux-claude-pr-review/config
```

```ini
orgs   = your-org, your-org
repos  = your-org/web-app
filter = all              # all | involves | review-requested | author | assigned
limit  = 50
clone_base     = ~/projects
session        = Code Review
review_command = /review
```

> **Tip on `filter`.** `all` lists *every* open PR in the orgs — which includes
> a lot of bot/infra noise (dependabot, CI). For an actual review queue you
> probably want `review-requested` (PRs awaiting your review) or `involves`
> (PRs you're part of). Keep specific `repos` if you want to see everything in
> those, and narrow `orgs` with the filter.

Point the plugin at a different config file with
`set -g @claude-pr-review-config '/path/to/config'`.

## Usage

Press **`prefix + R`** to open the picker.

| Key      | Action                                  |
| -------- | --------------------------------------- |
| `enter`  | Open / focus the review session for it  |
| `esc`    | Close the popup                         |
| (type)   | Fuzzy-filter the list                   |

On `enter`:

1. The **`Code Review`** session is created if missing.
2. A window **`<repo-name>#<pr-number>`** (e.g. `web-app#229`) is created
   if missing, in the repo's local clone (found under `clone_base`, else `$HOME`).
3. That window runs `claude "/review <pr-url>"`.
4. Re-selecting the same PR just focuses its window — Claude is not relaunched.

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

# Preview what it would do without touching tmux:
scripts/open_review.sh --dry-run <pr>
```

Behaviour:
- Idempotent — re-running for the same PR just refocuses its window; Claude is
  not relaunched.
- `--background` only suppresses switching your client to the review session
  (it does *not* open/raise the tmux window); the window and Claude are still
  created. Without it, your client switches to the review session.
- Prints `<session>:<window>` on success (or the pane id with `--print-pane`),
  so an automation can target the window afterwards.

## Configuration options (tmux)

```tmux
set -g @claude-pr-review-key           'R'    # prefix key (default: R)
set -g @claude-pr-review-width         '90%'  # popup width
set -g @claude-pr-review-height        '85%'  # popup height
set -g @claude-pr-review-preview-width '60%'  # preview share of the popup
set -g @claude-pr-review-config        '~/.config/tmux-claude-pr-review/config'
```

## Layout

```
claude_pr_review.tmux        # plugin entry (sourced/executed by TPM)
config.example               # sample config
scripts/
  config.sh                  # config locator + cfg() (sourced)
  list_prs.sh                # gh query -> one TSV line per PR
  picker.sh                  # fzf popup + gh pr view preview
  open_review.sh             # ensure session/window + launch claude "/review"
```
