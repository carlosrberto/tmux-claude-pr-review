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
./scripts/watch_list.sh --repos repos --filter mine   # the picker's "yours" list
./scripts/watch_list.sh --repos repos --filter all --no-skips   # its "all" list

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

To test without touching your real tmux server or launching real reviews: a
`tmux` wrapper (`exec /path/to/tmux -L prtest "$@"`) and fakes (`claude`,
`fzf`, `less`) first on `PATH`, `unset TMUX`, and a scratch
`@claude-pr-review-state-dir`. **Run the test as a script under `set -euo
pipefail` that first asserts `tmux display -p '#{socket_path}'` is the `prtest`
socket, and tear down only with `tmux -L prtest kill-server`.** A sourced
setup file that silently fails sends every bare `tmux` call — and any
`kill-server` — to the live server.

## Architecture

Four shell scripts; no build step. Data flows config → list → pick → act.

- **`scripts/config.sh`** — sourced by the others. `CFG_OPTIONS` lists every
  option; `load_cfg` reads them all in **one** `tmux display-message` (a
  `\037`-separated format) into `_CFG_<name>` vars, and `_opt`/`cfg`/`cfg_list`
  read those (unknown names fall back to `show-option`). Add new options to
  `CFG_OPTIONS` — doctor.sh flags anything else as unknown. The poller re-runs
  `load_cfg` each cycle. Also `find_clone` / `origin_slug` (shared).

- **`scripts/picker.sh`** — lists PRs via `watch_list.sh --repos repos`, in
  two modes toggled with `ctrl-a` (re-runs the query): "yours"
  (`@claude-pr-review-filter`, else the watch filter; watch skips apply) and
  "all" (`--filter all --no-skips`). Projects each record to hidden action fields
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
  needed to detect pushes). Also backs the picker (`--repos`, `--filter`,
  `--no-skips`). Filters skip-authors/labels client-side.
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
- **`scripts/notify.sh`** (sourced by state.sh) — `notify <event> <msg>
  [pr-key]` over the `@claude-pr-review-notify` channels: tmux, system
  (terminal-notifier/osascript/notify-send/wsl-notify-send.exe), terminal (OSC
  777/9 written straight to each client tty — no passthrough), cmd (env
  `PR_*`). Alerts (`done`, `attention`, `error`) reach every channel; info events
  only tmux + cmd. `notify_backend` is what doctor reports. terminal-notifier's
  click (`-execute`) runs `tmux -S <socket> switch-client -c <client tty> -t
  <window>` + `-activate <terminal bundle id>`; when it exits non-zero (macOS 26
  refuses the unsigned build) the alert falls back to osascript.
- **`scripts/doctor.sh`** — read-only health check; popup `ctrl-g` pages it
  through `less -R`.
- **`scripts/install_hooks.sh`** — idempotent jq merge into
  `<claude_config_dir>/settings.json`, with a backup.

Status flow: `baseline` (shown as ○ pending; `enter` in the popup starts it) |
`queued → reviewing ⇄ attention → done → seen`, and `done|seen → updated` on a
new push (re-review is manual: picker `ctrl-r` = `open_review.sh --replace`).
`dismissed` (popup `ctrl-x`) hides a PR without deleting its file — **never
`pr_rm` a still-matching PR**: the next poll would take it for a new request and
auto-review it. Files are only removed by `reconcile` once a PR stops matching.

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

- **The picker's "all" list is noisy** (release bots, drafts) by design — it
  skips nothing. That's why the picker opens on "yours".

- **Every word of the typed launch line is single-quoted (`sq`), not `printf
  %q`.** `%q` leaves a mid-word `#` bare (`--name web-app#229`), and zsh with
  `extendedglob` reads that as a glob: "no matches found".

- **Review env goes on the claude command line, not `new-window -e`.**
  `open_review.sh` types `CLAUDE_CONFIG_DIR=… CLAUDE_PR_REVIEW_KEY=…
  CLAUDE_PR_REVIEW_MARK=… claude …`. A `new-session -e` would set the
  *session* env and leak the key into every later window of "Code Review".
  The poller runs from tmux, which usually lacks a shell-rc `CLAUDE_CONFIG_DIR`
  — hence `@claude-pr-review-claude-config-dir`.

- **The Claude hooks never reference the plugin path** — they run
  `$CLAUDE_PR_REVIEW_MARK`, so they're no-ops in ordinary sessions and survive
  the plugin moving.

- **Don't `sleep <interval>` in the poller.** macOS pauses that timer in
  standby, so a due poll would run up to a full interval after waking.
  `wait_until` sleeps in 15s steps against the wall clock. Failed polls back off
  30s→1m→2m→4m→interval. Successful polls aren't logged; check `last-poll`.

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
