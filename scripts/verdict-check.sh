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
# The reason it gives comes from the summary of the reviewer's run (RUN_SUMMARY, written by
# review-summary.sh from claude-code-action's record) when there is one. Until 14 Oct 2026
# a green job with no verdict was always called "declined to run", so a run that read 25
# turns, was refused 6 actions and stopped (a 59-file PR) was explained as a PR editing the
# review workflow. Whether a verdict was found is written back into that summary.
#
# Env in: GH_TOKEN PR REPO HEAD_SHA RUN_URL TURNS REVIEW_RESULT RUNNER_TEMP
#         RUN_SUMMARY (optional: review-summary.sh's summary of the run)
#         GH (optional: the gh binary, so tests can substitute a stub)
set -euo pipefail

GH="${GH:-gh}"
: "${PR:?}" "${REPO:?}" "${HEAD_SHA:?}" "${RUNNER_TEMP:?}"

# --paginate prints one result per page, and a failed call prints nothing: reduce to a
# single integer so the numeric tests below cannot blow up under `set -e`. A failed call
# reads as zero and therefore announces, which is the safe direction.
count() { tr -cd '0-9\n' | awk '{s+=$1} END {print s+0}'; }

# Record the outcome in the run summary (uploaded after this step). Best effort.
note_verdict() {
  [ -n "${RUN_SUMMARY:-}" ] && [ -s "$RUN_SUMMARY" ] || return 0
  if jq --argjson v "$1" '.verdict_posted = $v' "$RUN_SUMMARY" > "$RUN_SUMMARY.tmp" 2>/dev/null; then
    mv "$RUN_SUMMARY.tmp" "$RUN_SUMMARY" || true
  else
    rm -f "$RUN_SUMMARY.tmp"
  fi
}

# A verdict counts only if it is the bot's AND it is about THIS commit. A stale approval
# from an earlier push must not vouch for code nobody has read.
# The login is matched with or without `[bot]`, as respond-gate.sh does. REST says
# `claude[bot]` today; if it ever says `claude`, an exact match would put a red check and
# "nothing has read this diff" on top of a real review, on every PR in every repo.
verdict="$("$GH" api "repos/$REPO/pulls/$PR/reviews" --paginate \
  --jq "[.[] | select(((.user.login // \"\") | sub(\"\\\\[bot\\\\]\$\"; \"\")) == \"claude\" and .commit_id == \"$HEAD_SHA\" and (.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\" or (.state == \"COMMENTED\" and ((.body // \"\") | startswith(\"<!-- pr-reviewer:needs-human -->\")))))] | length" \
  2>/dev/null | count || true)"

if [ "${verdict:-0}" -gt 0 ]; then
  echo "Verdict present for $HEAD_SHA — nothing to announce."
  note_verdict true
  exit 0
fi

echo "No claude[bot] verdict for $HEAD_SHA (job status: ${REVIEW_RESULT:-unknown})."
note_verdict false

# What the summary says (review-summary.sh: turns, and each refused action as one short
# line). No summary, or an unreadable one, leaves `ran` empty: the older wording below.
ran="" turns_used="" refused=0 refused_list=""
if [ -n "${RUN_SUMMARY:-}" ] && [ -s "$RUN_SUMMARY" ] \
   && jq -e 'type == "object" and has("refused")' "$RUN_SUMMARY" >/dev/null 2>&1; then
  ran=1
  turns_used="$(jq -r '.turns_used // empty' "$RUN_SUMMARY" 2>/dev/null || true)"
  refused="$(jq -r '.refused_count // (.refused | length) // 0' "$RUN_SUMMARY" 2>/dev/null || echo 0)"
  refused="${refused//[^0-9]/}"; refused="${refused:-0}"
  # One line per refused action, at most 10. Backticks and newlines are flattened so a
  # command cannot break out of the code block it is shown in.
  refused_list="$(jq -r '(.refused // [])[:10][]
      | ((.tool // "?") | tostring) + ": " + ((.input // "") | tostring)
      | gsub("[`\\r\\n]"; " ") | .[:200]' "$RUN_SUMMARY" 2>/dev/null || true)"
fi

# One plain sentence, used in the comment, the job summary and the red check's message.
if [ "${REVIEW_RESULT:-}" = "failure" ]; then
  reason="The reviewer stopped before reaching a verdict"
  [ -n "$turns_used" ] && reason="$reason after $turns_used of ${TURNS:-120} turns"
elif [ -n "$ran" ]; then
  reason="The reviewer ran${turns_used:+ for $turns_used of ${TURNS:-120} turns} but ended without posting a verdict"
  [ "${refused:-0}" -gt 0 ] && reason="$reason; it was refused $refused action(s) it is not allowed to take"
else
  reason="The reviewer declined to run"
fi

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
      printf '%s. The usual cause is a PR large ' "$reason"
      printf 'enough to exhaust the %s-turn budget just reading it — splitting it up gets each ' "${TURNS:-120}"
      printf 'part reviewed properly.\n\n'
    elif [ -n "$ran" ]; then
      printf '%s.\n\n' "$reason"
      if [ -n "$refused_list" ]; then
        printf 'What it was refused (first 10):\n\n```\n%s\n```\n\n' "$refused_list"
      fi
      printf 'This is a gap in the reviewer, not a problem with this PR. It needs a human '
      printf 'review before it merges, or a re-run once the reviewer is fixed.\n\n'
    else
      printf 'The reviewer declined to run. That normally means this PR changes the review '
      printf 'workflow itself, which it is not allowed to review — so this diff needs a human '
      printf 'before it merges.\n\n'
    fi
    printf '[Run log](%s) · A summary of the run (turns, refused actions) is saved on that page as `review-summary`. ' "${RUN_URL:-}"
    printf 'Push a change to re-run, or ask a human to review before merging.\n'
  } > "$RUNNER_TEMP/no-review.md"
  "$GH" pr comment "$PR" --repo "$REPO" --body-file "$RUNNER_TEMP/no-review.md" \
    || echo "::warning::Could not post the no-review comment."
else
  echo "Already announced for this commit — not commenting again."
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { printf '### No automated review for %s\n\n%s.\n' "$HEAD_SHA" "$reason"
    [ -n "$refused_list" ] && printf '\nRefused:\n\n```\n%s\n```\n' "$refused_list"
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo "::error::No automated review exists for $HEAD_SHA. $reason. This check is red so that is visible in the merge box."
exit 1
