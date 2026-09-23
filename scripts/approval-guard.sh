#!/usr/bin/env bash
# approval-guard.sh — withdraw an approval that landed on a commit the review did not read.
#
# Runs after the model in the `review` job. Deterministic: no model call. The model posts
# its approval with `gh pr review --approve`, and GitHub attaches it to whatever the head
# is AT THAT MOMENT — not to the commit that was read. A push landing mid-review would put
# this commit's green light on code nobody reviewed.
#
# Withdrawn (dismissed, with a message) = a claude[bot] APPROVED review submitted during
# this run (at or after SINCE) on any commit other than EXPECT_SHA. That is wrong whoever
# posted it. The `respond` job cannot approve at all (no `gh pr review` there), so the only
# bot approvals are the full review's.
# Never touched: a human's review, an older run's review, a CHANGES_REQUESTED verdict.
#
# Exit 1 (red) when a bad approval could not be withdrawn, or the reviews could not be read
# — "we could not check" must not look like "nothing to fix".
#
# Env in: GH_TOKEN REPO PR EXPECT_SHA SINCE (ISO 8601 UTC)
#         GH (optional: the gh binary, so tests can substitute a stub)
set -euo pipefail

GH="${GH:-gh}"
: "${REPO:?}" "${PR:?}" "${EXPECT_SHA:?}" "${SINCE:?}"

if ! bad="$("$GH" api "repos/$REPO/pulls/$PR/reviews" --paginate \
      --jq ".[] | select(((.user.login // \"\") | sub(\"\\\\[bot\\\\]\$\"; \"\")) == \"claude\")
                | select(.state == \"APPROVED\" and (.submitted_at // \"\") >= \"$SINCE\")
                | select(.commit_id != \"$EXPECT_SHA\")
                | \"\\(.id) \\(.commit_id)\"")"; then
  echo "::error::Could not read this PR's reviews, so could not confirm no approval landed on unreviewed code."
  exit 1
fi

[ -z "$bad" ] && { echo "No approval from this run on a commit it did not read."; exit 0; }

failed=0 last=""
while read -r id sha; do
  [ -z "$id" ] && continue
  last="it landed on ${sha:0:7}, but this run reviewed ${EXPECT_SHA:0:7} — the branch moved while it ran"
  if "$GH" api "repos/$REPO/pulls/$PR/reviews/$id/dismissals" -X PUT \
       -f message="Withdrawn automatically: $last." -f event=DISMISS >/dev/null; then
    echo "::warning::Withdrew approval $id: $last."
  else
    echo "::error::Could not withdraw approval $id ($last)."; failed=1
  fi
done <<< "$bad"

{
  printf '🤖 **Automated approval withdrawn.** '
  if [ "$failed" = 1 ]; then printf 'I tried to withdraw it and GitHub refused — **treat the approval above as void; a human must review before merging.** '; fi
  printf 'Reason: %s.\n\n' "$last"
  printf 'Nothing is wrong with your code because of this. The review of the latest commit follows your push.\n'
} > "${RUNNER_TEMP:-/tmp}/withdrawn.md"
"$GH" pr comment "$PR" --repo "$REPO" --body-file "${RUNNER_TEMP:-/tmp}/withdrawn.md" \
  || echo "::warning::Could not post the withdrawal note."

exit "$failed"
