# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A TPM-installable tmux plugin. `prefix + R` opens a `display-popup` with an
`fzf` list of open GitHub PRs (from `gh`) for configured repos; selecting
one opens a Claude Code review session for that PR.

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
./scripts/open_review.sh <repo-name> <pr-number> <pr-url>
```

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
  and binds the key.

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
  `install` (or omit for repo-wide changes).
- Examples:
  - `feat(list): query only the configured repos and dedupe by url`
  - `feat(review): launch claude with /review as the shell's initial command`
  - `fix(picker): keep url as a hidden field for the preview and action`
  - `docs(config): warn that filter=all includes bot PRs`
