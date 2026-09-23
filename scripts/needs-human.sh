#!/usr/bin/env bash
# needs-human.sh — the reviewer's third outcome: neither "safe to merge" nor "changes
# requested", but "a person has to decide this".
#
# Runs after the model in the `review` job. Deterministic: no model call. The model gives
# this verdict as a COMMENT review whose body starts with <!-- pr-reviewer:needs-human -->
# — for a change it cannot verify from this repository (a breaking API contract whose
# consumer it cannot see) or a diff too large to read whole. When this run posted one on
# HEAD_SHA, this script:
#   1. asks HUMAN to review (Philip, 23 Sep 2026: a PR needing a human goes to Camile,
#      the Tech Lead) and mentions them — or, on their own PR, mentions ESCALATE instead;
#   2. withdraws the bot's EARLIER approval or block. GitHub shows a reviewer's latest
#      approve/request-changes; a comment does not replace it, so without this the merge
#      box could still say "approved" from an older commit.
#
# Exit 1 (red) when an older bot verdict could not be withdrawn — the merge box would then
# say something this review no longer stands behind — or when THIS run posted another
# verdict beside the needs-a-human: the merge box would show that one, so a person must
# look, and nothing is withdrawn. A refused reviewer request is only a
# warning: the mention still notifies.
#
# Env in: GH_TOKEN REPO PR HEAD_SHA SINCE (ISO 8601 UTC) HUMAN (GitHub login)
#         ESCALATE (default @designbluemanila-create)
#         GH (optional: the gh binary, so tests can substitute a stub)
set -euo pipefail

GH="${GH:-gh}"
: "${REPO:?}" "${PR:?}" "${HEAD_SHA:?}" "${SINCE:?}" "${HUMAN:?}"
ESCALATE="${ESCALATE:-@designbluemanila-create}"
MARK='<!-- pr-reviewer:needs-human -->'
bot='select(((.user.login // "") | sub("\\[bot\\]$"; "")) == "claude")'

if ! reviews="$("$GH" api "repos/$REPO/pulls/$PR/reviews" --paginate \
      --jq ".[] | $bot | {id, state, commit_id, submitted_at: (.submitted_at // \"\"), body: (.body // \"\")} | @json")"; then
  echo "::error::Could not read this PR's reviews."; exit 1
fi

this="$(printf '%s\n' "$reviews" | jq -r --arg h "$HEAD_SHA" --arg s "$SINCE" --arg m "$MARK" \
  'select(.state == "COMMENTED" and .commit_id == $h and .submitted_at >= $s and (.body | startswith($m))) | .submitted_at' | tail -1)"
[ -z "$this" ] && { echo "No needs-a-human verdict in this run."; exit 0; }

also="$(printf '%s\n' "$reviews" | jq -r --arg s "$SINCE" \
  'select((.state == "APPROVED" or .state == "CHANGES_REQUESTED") and .submitted_at >= $s) | .state' | sort -u | paste -sd, -)"
failed=0 conflict=""
if [ -n "$also" ]; then
  echo "::error::This run posted a needs-a-human verdict AND $also — the merge box shows the latter. Nothing withdrawn; a person has to look."
  failed=1
  conflict=" **This run also posted a conflicting automated verdict ($also): treat it as void — the merge box is wrong until you decide.**"
fi

# 2. the bot's earlier verdicts (from before this run) step aside — not on a conflicting run
[ -n "$conflict" ] || for id in $(printf '%s\n' "$reviews" | jq -r --arg s "$SINCE" \
              'select((.state == "APPROVED" or .state == "CHANGES_REQUESTED") and .submitted_at < $s) | .id'); do
  if "$GH" api "repos/$REPO/pulls/$PR/reviews/$id/dismissals" -X PUT \
       -f message="Superseded: the latest automated review needs a human decision (see below)." -f event=DISMISS >/dev/null; then
    echo "Withdrew earlier verdict $id."
  else
    echo "::error::Could not withdraw earlier verdict $id — the merge box may still show it."; failed=1
  fi
done

# 1. ask the person
author="$("$GH" api "repos/$REPO/pulls/$PR" --jq '.user.login' 2>/dev/null || true)"
who="@$HUMAN"
if [ "$author" = "$HUMAN" ]; then
  who="$ESCALATE"
elif ! "$GH" api "repos/$REPO/pulls/$PR/requested_reviewers" -X POST -f "reviewers[]=$HUMAN" >/dev/null 2>&1; then
  echo "::warning::Could not add $HUMAN as a reviewer; the mention below still notifies."
fi

marker="<!-- pr-reviewer:needs-human-ping:$HEAD_SHA -->"
# read ALL pages first: `gh … | grep -q` stops reading at the first match, gh dies of a
# broken pipe on the next page, and under pipefail "found" reads as "not found"
existing="$("$GH" api "repos/$REPO/issues/$PR/comments" --paginate --jq '.[].body // ""' 2>/dev/null || true)"
if grep -qF "$marker" <<< "$existing"; then   # no pipe: nothing left to break
  echo "Already asked for this commit."
else
  printf '%s\n\n🤖 %s — this pull request needs a human decision. The review above says what I could not verify and what would settle it. Nothing is blocked or approved by me until then.%s\n' \
    "$marker" "$who" "$conflict" > "${RUNNER_TEMP:-/tmp}/needs-human.md"
  "$GH" pr comment "$PR" --repo "$REPO" --body-file "${RUNNER_TEMP:-/tmp}/needs-human.md" \
    || echo "::warning::Could not post the note."
fi
exit "$failed"
