# Releasing a change to the shared workflow

Twenty-six repositories call `review.yml` from this repository. Before 16 Sep 2026 they
all called it at `@main`, which meant **every merge here was an immediate, unstaged
production deploy to every repo we work in**. On 16 Sep one merge stopped the reviewer
starting at all on 23 of them, and the only thing that surfaced it was a developer
noticing his pull requests had no checks.

Callers now pin to a tag. `main` is where work lands; the tag is what the fleet runs.

## The two states

| | what it is | who follows it |
|---|---|---|
| `main` | latest reviewed work | nothing in production |
| `v1` | what every caller runs | all 26 repos |

## Shipping a change

1. **PR into `main`.** `Self check` runs: the caller contract, actionlint on both
   workflows, and the `build.sh` fixtures. It has to be green.
2. **Merge.** Nothing in the field changes. This is the point of the tag.
3. **Move the tag** when you actually want the fleet on it:

   ```
   git fetch origin
   git tag -f v1 origin/main
   git push -f origin v1
   ```

4. **Watch one repo.** Open or push to any PR in a repo that uses the reviewer and
   confirm the `build` and `review` checks appear and complete. "No checks at all" is
   the shape a broken shared workflow takes — not a red check.

## Rolling back

```
git tag -f v1 <last good sha>
git push -f origin v1
```

Seconds, and no pull request anywhere. That is the whole reason the tag exists.

## Changing what callers must grant

The caller contract (`scripts/check-caller-contract.py`) pins the permission set every
caller in the field grants. A job in `review.yml` may never ask for more, because a
called workflow's permissions must be a **subset** of its caller's, and GitHub responds
to a violation by refusing to start the entire workflow — build and review included.

To raise it, in this order:

1. Update `caller-template.yml` with the wider grant.
2. Roll the new caller to **every** repo and merge them all:
   `_shared/pr-reviewer-rollout/rollout.sh --update --tier all --branch chore/… --title …`
3. Only then raise `FIELD_GRANTS` in the contract script, in its own PR that says
   step 2 is done.

Doing this the other way round is exactly what caused the 16 Sep outage.
