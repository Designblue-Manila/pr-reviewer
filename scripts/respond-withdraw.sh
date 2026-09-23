#!/usr/bin/env bash
# respond-withdraw.sh — pull the bot's approval when a reply confirmed a defect it missed.
#
# The `respond` job's model cannot submit a review (Philip, 23 Sep 2026: a reply never
# approves; after a won argument the full review of the next push gives the green light).
# It can still take a green light BACK: when it has verified a real defect it missed, its
# one comment ends with
#     <!-- pr-reviewer:verdict=request-changes -->
# as its LAST line, and this script — deterministic, no model call — dismisses the
# claude[bot] approvals standing on the commit the reply read (GATE_HEAD) or posted before
# the reply began, pointing at that comment. An approval that arrived WHILE it ran, on a
# newer commit — a push that may well have fixed it — is the full review's, not this reply's.
#
# Only the reviewer's own comments made during this run (at or after SINCE) count; the
# marker in a person's comment means nothing. Exit 1 when the PR cannot be read or GitHub
# refuses the dismissal, so an approval that should be gone never stays silently.
#
# Env in: GH_TOKEN REPO PR GATE_HEAD SINCE (ISO 8601 UTC)
#         GH (optional: the gh binary, so tests can substitute a stub)
set -euo pipefail

GH="${GH:-gh}"
: "${REPO:?}" "${PR:?}" "${GATE_HEAD:?}" "${SINCE:?}"
bot='select(((.user.login // "") | sub("\\[bot\\]$"; "")) == "claude")'

if ! url="$("$GH" api "repos/$REPO/issues/$PR/comments" --paginate \
      --jq ".[] | $bot | select((.created_at // \"\") >= \"$SINCE\")
                | select((.body // \"\") | sub(\"\\\\s+$\"; \"\") | split(\"\\n\") | (last // \"\") | sub(\"^\\\\s+\"; \"\")
                         | . == \"<!-- pr-reviewer:verdict=request-changes -->\")
                | .html_url" | tail -1)"; then
  echo "::error::Could not read this PR's comments."; exit 1
fi
[ -z "$url" ] && { echo "No request to pull an approval in this reply."; exit 0; }

# claude[bot] reviews still APPROVED (a dismissed one reads DISMISSED)
if ! ids="$("$GH" api "repos/$REPO/pulls/$PR/reviews" --paginate \
      --jq ".[] | $bot | select(.state == \"APPROVED\")
                | select(.commit_id == \"$GATE_HEAD\" or (.submitted_at // \"\") < \"$SINCE\") | .id")"; then
  echo "::error::Could not read this PR's reviews, so the approval may still stand."; exit 1
fi
[ -z "$ids" ] && { echo "No standing approval to pull."; exit 0; }

failed=0
for id in $ids; do
  if "$GH" api "repos/$REPO/pulls/$PR/reviews/$id/dismissals" -X PUT \
       -f message="Withdrawn: a defect the review missed was confirmed — see $url" -f event=DISMISS >/dev/null; then
    echo "Pulled approval $id."
  else
    echo "::error::GitHub refused to withdraw approval $id — it still stands."; failed=1
  fi
done
exit "$failed"
