# pr-reviewer

One shared, automated pull-request reviewer for every repository we work in. It builds
and tests each PR, reads everything that depends on the change, posts line-pinned
findings, and gives one verdict: **approved** (safe to merge — the author merges) or
**changes requested** (fix, push, it re-reviews). Argue with a finding in a PR comment
and it answers: it re-checks its own claim and says whether it stands or is withdrawn.

It never merges, never pushes, never edits code.

## How it works

```
repo/.github/workflows/pr-review.yml   (from caller-template.yml)
        │  on: pull_request          → build + review
        │  on: issue_comment,        → respond
        │      pull_request_review_comment
        ▼
Designblue-Manila/pr-reviewer/.github/workflows/review.yml
        ├─ job build    scripts/build.sh — install, build, boot, migrate, test. No AI.
        │               Red check when something fails; logs kept as an artifact.
        ├─ job review   Claude (Opus) reads the diff, the build logs, REVIEW-STANDARDS.md
        │               and the repo's own .github/REVIEW-NOTES.md, traces the impact
        │               radius, comments inline, then approves or requests changes.
        └─ job respond  someone answered back. Claude re-checks its own standing findings
                        against the code and posts one comment: per finding, stands /
                        withdrawn / needs a human. No build, no fresh review. Runs only
                        while the reviewer is blocking the PR, only for comments by
                        people, and never on a fork PR.
```

- **Identity.** The review is posted by the Claude GitHub App (`claude`), which must be
  installed on the organisation or account that owns the repo.
- **Login.** Each repo carries a `CLAUDE_CODE_OAUTH_TOKEN` secret (a Claude subscription
  token from `claude setup-token`). The caller passes it explicitly; `secrets: inherit`
  does not reach a workflow owned by a different account.
- **What is checked** is written in [REVIEW-STANDARDS.md](REVIEW-STANDARDS.md). That
  file is the rulebook; change it by PR here and every repo follows on its next review.
- **Releases.** Callers pin to the `v1` tag, not `main` — merging here changes nothing
  in the field until the tag moves, and rolling back is moving it back. The process,
  and why it exists, is in [RELEASING.md](RELEASING.md).
- **Self check.** Every PR here runs `scripts/check-caller-contract.py`, which fails if
  any job in `review.yml` asks for a permission the callers in the field do not grant.
  That mistake does not degrade the reviewer, it stops it starting at all, fleet-wide.

## Add a repository

1. Install the Claude GitHub App on the owner (github.com/apps/claude) if not yet.
2. Add the secret: `gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo OWNER/REPO`.
3. Copy `caller-template.yml` to `.github/workflows/pr-review.yml` and open a PR.
4. Remove any older per-repo Claude review workflow in the same PR.

On that first PR only the `build` job is meaningful: the Claude action validates the
workflow against the default branch before it takes a token, so the first real review
lands on the next PR opened after the caller is merged.

Optional: a `.github/REVIEW-NOTES.md` in the repo with waivers and context the reviewer
should know (which folder is generated, which repo consumes this API, an agreed design
exception). It cannot relax security, data, build or impact rules.

## Day to day

| Want to… | Do this |
|---|---|
| Skip the review on one PR | Add the label `no-review` before pushing. |
| Save minutes while still working | Keep the PR a draft; drafts are not reviewed. |
| Re-run a review | Push a commit, or re-run the workflow from the Actions tab. |
| No run after a push | The PR's diff against the base is empty or only touches ignored paths (`**.md`, `docs/**`); GitHub then skips the workflow. |
| Read why the build went red | Open the run → artifact `build-results` → the project's `*.log`. |
| Change a rule | PR to `REVIEW-STANDARDS.md`. |
| Swap the model | `with: model:` in the caller (see `caller-template.yml`). |
| Move to a pay-per-use key | Set `ANTHROPIC_API_KEY` in the repo and change `claude_code_oauth_token` to `anthropic_api_key` in `review.yml`. |

## The verdict, and what the author does

- **Approved** — the body starts "safe to merge. You can merge this to `<base>` now" and
  lists what was checked: build, tests, impact radius, cross-repo, nits. The author
  merges their own PR.
- **Changes requested** — every Important item is listed as `file:line — what breaks —
  the fix`, and pinned inline. Fix, push; the reviewer checks its own list again and
  approves once it is empty and the build is green.

GitHub emails the author on both.

## What the build job does

`scripts/build.sh` finds every project in the repo (root, or up to four levels down for
monorepos), then per project:

- **Node** — detects pnpm / yarn / npm from `packageManager` or the lockfile, Node version
  from `.nvmrc`, `.node-version` or `engines.node` (default 22), installs with the
  lockfile frozen (falls back and notes `lockfile=out-of-sync`), runs `lint`, `build`
  and `test` where the scripts exist.
- **PHP / Laravel** — PHP version from `composer.json`, `php -l` on changed files,
  `composer install`, boots the app (`artisan about`), runs migrations on a fresh
  database (MySQL, or SQLite when `phpunit.xml` says so), runs the test suite. Test
  failures that are clearly the CI environment are reported as `unrunnable`, not red.
- **WordPress** — `php -l` on changed PHP files.
- A sub-project the PR did not touch is skipped.

Result: one line per project in the job summary and in the artifact's `summary.txt`,
plus per-project logs.

## Token renewal

Subscription tokens last about a year. When reviews start failing with an
authentication error, run `claude setup-token` again and update the secret in every
repo (the rollout tooling does this in one go).

## Security posture

- The review job's Claude has read tools, `gh pr view/diff/review/comment`, `git
  log/diff/show` and the inline-comment tool. No write tools, no `git push`, no
  `gh api`, no web access, no shell beyond those commands.
- The build job runs the PR's own install scripts, so it checks out with
  `persist-credentials: false` and has no secrets.
- Fork PRs never run. PR text is treated as untrusted input.
- On GitHub Free the verdict is advisory: nothing stops a merge without approval.
  Branch protection (a paid plan) is what makes "author merges after approval" a rule
  GitHub enforces.
