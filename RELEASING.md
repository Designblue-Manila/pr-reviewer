# Releasing a change to the shared workflow

Every repository we work in calls `review.yml` from this one. Before 16 Sep 2026 they all
called it at `@main`, which meant **every merge here was an immediate, unstaged production
deploy to every repo at once**. On 16 Sep one merge stopped the reviewer starting at all on
23 of them, and the only thing that surfaced it was a developer noticing his pull requests
had no checks.

Callers pin to a tag. `main` is where work lands; a tag is what runs.

## The tags

| | what it is | who follows it |
|---|---|---|
| `main` | latest reviewed work | nothing in production |
| `v2-canary` | the next release, being proven | two canary repos (one Laravel, one Nuxt). Their caller is the template with this tag in place of `v2` — the only permitted difference, and `fleet.sh` knows it. |
| `v2` | the release | every thin caller — the current `caller-template.yml` |
| `v1` | the same commit as `v2` | callers installed before 21 Sep 2026, which still carry their own filter. Retires when `fleet.sh census` shows nothing pinned to it. |

`v1` and `v2` always sit on the same commit. They are separate names for one reason:
**`v2` has never pointed at a `review.yml` that does not gate itself**, so a thin caller can
never meet one (see "The floor").

## Shipping a change

1. **PR into `main`.** `Self check` runs: the caller contract and gates, `tests/run.sh`,
   actionlint, the `build.sh` fixture. It has to be green. It is a person's review too —
   the reviewer cannot review a pull request that edits its own workflow, and says so.
2. **Merge.** Nothing in the field changes.
3. **Canary.** `scripts/release.sh canary` re-runs the checks against the commit and prints
   the two commands that move `v2-canary`. Run them, then reopen the standing test PR in
   each canary repo. Each carries a planted defect: expect the `build` and `review` checks
   to appear, and the review to request changes **naming that defect**. In the `build` log,
   "Which release is this" must show `scripts=` equal to `workflow_sha=`.
4. **Fleet.** `scripts/release.sh fleet` refuses unless the canary is on that exact commit,
   then prints the commands for `v1` and `v2`, in order. `scripts/release.sh status`
   afterwards: all three tags on one commit.

`release.sh` never pushes. Moving a release tag is a forced push to a repo every project
depends on; the script does the checking, a person runs the commands.

"No checks at all" is the shape a broken shared workflow takes — not a red check. That is
why step 3 exists: the canary finds it on two repos instead of a developer finding it on
twenty-seven.

## Rolling back

`scripts/release.sh fleet <last good commit>` — the same checks, the same commands, seconds,
no pull request anywhere. It skips nothing on a rollback, including the floor.

## The floor

Since 21 Sep 2026 the draft / fork / label / bot-comment filter lives in `review.yml`'s
job-level `if`s, not in the callers. A thin caller filters nothing. On a `review.yml` from
before that change, a thin caller would let the `respond` job answer the bot's own comments
— a loop, paid for out of one person's Claude subscription.

So no release tag may ever point below the first gated commit. `release.sh` enforces it by
content: it runs **today's** contract checker against the target commit's files. The floor
is that checker's own rules — every gate carries its mandatory clauses, carries no `||`
beyond the one `respond` needs (an extra `||` is how a gate gets widened while still
"containing" every clause), and no job asks for more than the field grants.
`tests/gates.golden` is not part of the floor: it makes a gate change visible in review,
and a person reviewing that diff is the check on a change that is deliberate but wrong —
the reviewer cannot review a PR that edits its own workflow. Behind all of it,
`scripts/respond-gate.sh` re-checks the comment author itself and carries a circuit breaker
(more than 6 automated comments on one PR in an hour → it stops answering).

## What can change by moving a tag, and what cannot

| Moves with the tag | Costs a pull request in every repo, on every long-lived branch |
|---|---|
| The review and reply prompts, `REVIEW-STANDARDS.md`, `build.sh` | The events that wake the workflow (`on:`) and `paths-ignore` |
| What runs and what is skipped: drafts, forks, labels, bot comments | The permissions the caller grants |
| What cancels what (concurrency) | The pinned tag name itself |
| Model, turn limit, timeouts | |

The right-hand column is why `caller-template.yml` grants `checks: read` and
`actions: read` before anything uses them: asking later would mean another fleet round.

## Changing what callers must grant

The caller contract (`scripts/check-caller-contract.py`) pins the permission set every
caller in the field grants (`FIELD_GRANTS`). A job in `review.yml` may never ask for more,
because a called workflow's permissions must be a **subset** of its caller's, and GitHub
responds to a violation by refusing to start the entire workflow — build and review included.

To raise it, in this order:

1. Update `caller-template.yml` with the wider grant.
2. Roll the new caller to **every** repo and branch, and get them all merged:
   `_shared/pr-reviewer-rollout/fleet.sh update` (dry run; `--apply` opens the PRs).
3. `fleet.sh verify` — every caller identical to the template. Only then raise
   `FIELD_GRANTS`, in its own PR that says step 3 passed.

Doing this the other way round is exactly what caused the 16 Sep outage. As of 21 Sep 2026
the template grants `checks: read` and `actions: read` but `FIELD_GRANTS` does not include
them yet: nothing in `review.yml` may use them until the fleet round is verified.
