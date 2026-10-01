# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A TPM-installable tmux plugin. `prefix + R` opens a `display-popup` with an
`fzf` list of open GitHub PRs (from `gh`) for configured repos; selecting
one opens a Claude Code review session for that PR. **Watch mode** polls in the
background and opens review sessions for new matching PRs on its own, with a
status-line segment fed by Claude Code + tmux hooks.

## Commands

```sh
# List PRs (the core data step); reads the config and queries gh:
./scripts/list_prs.sh
./scripts/list_prs.sh | column -t -s "$(printf '\t')"

# Lint (the only gate — no build/test suite):
shellcheck claude_pr_review.tmux scripts/*.sh

# Load/reload the binding the way TPM does (execute it; do NOT tmux source-file):
bash ./claude_pr_review.tmux
tmux list-keys -T prefix R

# Exercise a review launch directly (creates a real session + runs claude):
./scripts/open_review.sh <pr-url>
./scripts/open_review.sh --dry-run <pr-url>

# Watch mode:
./scripts/watch_list.sh            # what watch mode would review (TSV)
./scripts/watch.sh status          # on/off, poller, last poll, tracked PRs
./scripts/watch.sh poll            # one poll in the foreground
./scripts/install_hooks.sh --dry-run
```

To test watch mode without touching your real tmux or launching real reviews,
put a `tmux` wrapper (`exec tmux -L prtest "$@"`) and a fake `claude` (logs its
env/args, sleeps) first on `PATH`, `unset TMUX`, and point
`@claude-pr-review-state-dir` at a scratch dir on that test server.

## Architecture

Four shell scripts; no build step. Data flows config → list → pick → act.

- **`scripts/config.sh`** — sourced by the others. Reads configuration from
  `@claude-pr-review-*` tmux options and exposes `cfg <logical-key>` (scalars)
  and `cfg_list <logical-key>` (the repos list, split on commas/whitespace).
  `cfg` maps logical keys to option names, so callers stay option-agnostic.

- **`scripts/list_prs.sh`** — emits one TSV record per PR:
  `url <TAB> repoWithOwner <TAB> repoName <TAB> number <TAB> title <TAB> author`.
  Only the repos in `@claude-pr-review-repos` are queried — one `gh search prs`
  call with a `--repo=` flag per repo (deduped by URL). The `filter` option maps
  to a gh `@me` qualifier (`involves`/`review-requested`/`author`/`assigned`);
  `all` adds none. Uses gh's built-in `--jq` — no standalone jq dependency.

- **`scripts/picker.sh`** — projects the record to hidden action fields
  (`url`, `repoName`, `number`) plus an aligned display block, then `fzf`
  (`--with-nth=4..` hides the action fields, `{1}=url` drives the
  `gh pr view` preview). On selection it `exec`s open_review.sh.

- **`scripts/open_review.sh <repo> <num> <url>`** — ensures the `session`
  (default "Code Review") and a `"<repo>#<num>"` window exist, then launches the
  review.

- **`claude_pr_review.tmux`** — TPM entry; reads `@claude-pr-review-*` options
  and binds the keys, rewrites `#{claude_pr_review_status}` in
  status-left/right, sets the "seen" tmux hooks, and (re)starts the poller.

### Watch mode

- **`scripts/state.sh`** (sourced) — the on-disk state is the source of truth:
  one `key=value` file per PR in `<state_dir>/prs/<owner>__<repo>__<num>`, plus
  `enabled`, `watch.pid`, `watch.lock/`, `last-poll`, `baselined`, `watch.log`.
  `pr_set` is a locked read-modify-write ending in an atomic `mv` (the poller,
  Claude hooks, tmux hooks and picker all write). `render_status` derives
  `@claude-pr-review-status` from the files — the status line only reads that
  option.
- **`scripts/watch_list.sh`** — `owner/name[:filter]` repos grouped by filter;
  one `gh api graphql` search per qualifier (`gh search prs` has no head SHA,
  needed to detect pushes). Filters skip-authors/labels client-side.
- **`scripts/watch.sh`** — `poll` (baseline on first run → queue new PRs → mark
  pushed-to reviewed PRs `updated` → reconcile → `dispatch`), `dispatch` (open
  queued reviews up to `watch-max`), `loop`/`start`/`stop`/`toggle`/`status`.
  `start` is a restart, so a config reload picks up new code.
- **`scripts/mark.sh`** — status transitions: `done`/`attention` from the Claude
  Stop/Notification hooks (key from `$CLAUDE_PR_REVIEW_KEY`), `seen` from tmux
  hooks. Always exits 0.
- **`scripts/status_picker.sh`** / **`status_preview.sh`** — `prefix +
  @claude-pr-review-status-key` popup over the state files (not gh); preview is
  `capture-pane -e -J` of the review window. Icons are padded apart from labels
  because BSD awk's `length` counts bytes.
- **`scripts/cleanup.sh`** — closes windows + removes review worktrees of
  finished reviews (popup `ctrl-d`/`ctrl-x`); local only. Keeps PRs tracked
  (`done→seen`) so a poll doesn't re-queue them. The clone comes from the `clone`
  field `open_review.sh` records (fallback: the window's pane path); a worktree is
  removed only if `git worktree list` has it.
- **`scripts/install_hooks.sh`** — idempotent jq merge into
  `<claude_config_dir>/settings.json`, with a backup.

Status flow: `baseline` | `queued → reviewing ⇄ attention → done → seen`, and
`done|seen → updated` on a new push (re-review is manual: picker `ctrl-r` =
`open_review.sh --replace`).

### Things that are easy to get wrong

- **Launch the review by typing into the fresh shell, not Claude's TUI.**
  open_review.sh `send-keys` the line `claude "/review <url>"` into the new
  window's shell (ready immediately), letting the shell start Claude with the
  review prompt as its initial argument. Do NOT send `claude`, then try to type
  `/review` into the TUI — that races startup. Claude only launches in a
  *newly created* window; re-selecting a PR just refocuses.

- **Window names contain `#`** (`web-app#229`). Target tmux by the
  captured `#{pane_id}` (from `new-window -P -F`), not by `session:name`, to stay
  unambiguous. Use exact session matches (`-t "=$session"`); the session name has
  a space ("Code Review").

- **`filter = all` is noisy.** Org-wide listing pulls in dependabot/CI/infra
  PRs. For a real review queue, `review-requested` or `involves` is usually what
  you want. Worth keeping in mind when changing defaults.

- **Review env goes on the claude command line, not `new-window -e`.**
  `open_review.sh` types `CLAUDE_CONFIG_DIR=… CLAUDE_PR_REVIEW_KEY=…
  CLAUDE_PR_REVIEW_MARK=… claude …`. A `new-session -e` would set the
  *session* env and leak the key into every later window of "Code Review".
  The poller runs from tmux, which usually lacks a shell-rc `CLAUDE_CONFIG_DIR`
  — hence `@claude-pr-review-claude-config-dir`.

- **The Claude hooks never reference the plugin path** — they run
  `$CLAUDE_PR_REVIEW_MARK`, so they're no-ops in ordinary sessions and survive
  the plugin moving.

- **`tmux display-message -t <gone-window>` exits 0.** Check a window exists
  with `list-windows -a -F '#{window_id}' | grep -qx` (`window_alive`).

- **The tmux "seen" hooks also fire for background `select-window`** (the
  poller's dispatch) — `mark.sh seen` checks the window is active in an
  attached session first. Hooks use fixed array index `[71]` so reloads don't
  stack duplicates or clobber the user's hooks.

- **bash 3.2 / BSD awk traps hit here:** a `case` inside `$(…)` doesn't parse
  (use a function); BSD awk rejects newlines in `-v` values (use `ENVIRON`);
  backslashes written inline in a `${var//pat/rep}` replacement are kept (put
  pattern/replacement in variables). `sd` treats `$name` in replacements as a
  capture group — don't use it to edit shell code.

- **Depends on `gh` being authenticated** and on the right account
  (`gh auth status`); `@me` resolves to the active account.

## Releasing

The version lives in the top-level **`VERSION`** file; the git tag is the
canonical distribution version. Cut a release by tagging:

```sh
git tag -a v0.1.0 -m "Release v0.1.0" && git push --follow-tags
```

## Commits & branches

Use **Conventional Commits** for both branch names and commit messages, and keep
history **linear**.

**No AI attribution.** Do **not** add `Co-Authored-By: Claude…` or "Generated
with Claude Code" trailers/footers to commits in this repo.

**No merge commits — always rebase.** Integrate a branch by rebasing onto the
base, then fast-forwarding (`git merge --ff-only`). `main` stays a straight line.

**Branches:** `<type>/<short-description>` in kebab-case (no ticket prefix).
- Types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`.
- Examples: `feat/review-requested-filter`, `fix/window-name-targeting`,
  `docs/config-filter-tip`.

**Commit messages:** `<type>(<scope>): <subject>` — imperative, lowercase, no
trailing period.
- Scope = the area touched: `config`, `list`, `picker`, `review`, `tmux`,
  `install`, `watch`, `hooks` (or omit for repo-wide changes).
- Examples:
  - `feat(list): query only the configured repos and dedupe by url`
  - `feat(review): launch claude with /review as the shell's initial command`
  - `fix(picker): keep url as a hidden field for the preview and action`
  - `docs(config): warn that filter=all includes bot PRs`
