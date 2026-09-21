#!/usr/bin/env bash
# verdict-check.sh — ask GitHub whether a verdict actually exists for this commit. When it
# does not: say so in the PR, and FAIL the job.
#
# Checking the OUTCOME rather than enumerating failure modes, because the modes do not
# look alike and the dangerous one is green:
#   - crash (ib-e-shop-cms#9, 17 Sep 2026): turn limit hit, job red, PR merged unreviewed
#     anyway. A red tick reads as "some check is unhappy", not "nothing read your code".
#   - skip (pr-reviewer#14, 18 Sep 2026): claude-code-action refuses to run when the
#     workflow file differs from the default branch's copy — correct, it stops a PR editing
#     the reviewer that is reviewing it — but it exits `conclusion=success`. The check went
#     GREEN with no review at all.
# Any future silent no-op lands in the same net without another patch here.
#
# The exit code matters as much as the comment. We cannot block a merge (branch protection
# is a paid feature these private repos do not have), so the two signals left are a comment,
# which notifies the author, and a red `review` check, which is what they see in the merge
# box. Until 21 Sep 2026 the skip case commented and then stayed green.
#
# Env in: GH_TOKEN PR REPO HEAD_SHA RUN_URL TURNS REVIEW_RESULT RUNNER_TEMP
#         GH (optional: the gh binary, so tests can substitute a stub)
set -euo pipefail

GH="${GH:-gh}"
: "${PR:?}" "${REPO:?}" "${HEAD_SHA:?}" "${RUNNER_TEMP:?}"

# --paginate prints one result per page, and a failed call prints nothing: reduce to a
# single integer so the numeric tests below cannot blow up under `set -e`. A failed call
# reads as zero and therefore announces, which is the safe direction.
count() { tr -cd '0-9\n' | awk '{s+=$1} END {print s+0}'; }

# A verdict counts only if it is the bot's AND it is about THIS commit. A stale approval
# from an earlier push must not vouch for code nobody has read.
# The login is matched with or without `[bot]`, as respond-gate.sh does. REST says
# `claude[bot]` today; if it ever says `claude`, an exact match would put a red check and
# "nothing has read this diff" on top of a real review, on every PR in every repo.
verdict="$("$GH" api "repos/$REPO/pulls/$PR/reviews" --paginate \
  --jq "[.[] | select(((.user.login // \"\") | sub(\"\\\\[bot\\\\]\$\"; \"\")) == \"claude\" and .commit_id == \"$HEAD_SHA\" and (.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\"))] | length" \
  2>/dev/null | count || true)"

if [ "${verdict:-0}" -gt 0 ]; then
  echo "Verdict present for $HEAD_SHA — nothing to announce."
  exit 0
fi

echo "No claude[bot] verdict for $HEAD_SHA (job status: ${REVIEW_RESULT:-unknown})."

# Re-running the job on the same commit must not stack a second copy of the comment.
marker="<!-- pr-reviewer:no-review:$HEAD_SHA -->"
have="$("$GH" api "repos/$REPO/issues/$PR/comments" --paginate \
  --jq "[.[] | select(.body | contains(\"$marker\"))] | length" 2>/dev/null | count || true)"

if [ "${have:-0}" -eq 0 ]; then
  # Built with printf, not a heredoc: this used to live in YAML, where block indentation
  # was carried into the body and GitHub rendered the whole comment as code.
  {
    printf '%s\n\n' "$marker"
    printf '🤖 **No automated review on this commit — nothing has read this diff.**\n\n'
    printf 'This is not a rejection, and the absence of an approval is not an approval.\n\n'
    if [ "${REVIEW_RESULT:-}" = "failure" ]; then
      printf 'The reviewer stopped before reaching a verdict. The usual cause is a PR large '
      printf 'enough to exhaust the %s-turn budget just reading it — splitting it up gets each ' "${TURNS:-120}"
      printf 'part reviewed properly.\n\n'
    else
      printf 'The reviewer declined to run. That normally means this PR changes the review '
      printf 'workflow itself, which it is not allowed to review — so this diff needs a human '
      printf 'before it merges.\n\n'
    fi
    printf '[Run log](%s) · Push a change to re-run, or ask a human to review before merging.\n' "${RUN_URL:-}"
  } > "$RUNNER_TEMP/no-review.md"
  "$GH" pr comment "$PR" --repo "$REPO" --body-file "$RUNNER_TEMP/no-review.md" \
    || echo "::warning::Could not post the no-review comment."
else
  echo "Already announced for this commit — not commenting again."
fi

echo "::error::No automated review exists for $HEAD_SHA. This check is red so that is visible in the merge box."
exit 1
