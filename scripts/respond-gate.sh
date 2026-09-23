#!/usr/bin/env bash
# respond-gate.sh — decide whether the `respond` job has anything to answer.
#
# Runs BEFORE the pull request's code is checked out, so nothing a stranger wrote is on
# disk yet. Deterministic: no model call. Writes `answer=true|false` (plus head, base,
# build, verdict) to $GITHUB_OUTPUT, and may post one marker-guarded comment.
#
# It lived inline in review.yml until 21 Sep 2026 and was tested by replaying error text
# by hand. It is a script so tests/run.sh can drive every branch from fixture JSON.
#
# Layers, in order. Each one alone is enough to stop the job:
#   1. the comment's author is a bot            (the job `if` already said so — belt and braces:
#                                                an answer to our own comment is an infinite loop
#                                                paid for out of one person's subscription)
#   2. public repo, commenter is a stranger     (anyone on the internet can comment there)
#   3. circuit breaker                          (more than MAX_REPLIES_PER_HOUR bot replies on this PR)
#   4. fork pull request                        (comment events carry no head-repo field to filter on)
#   5. nothing to adjudicate                    (closed, draft, or no verdict on record)
#
# Env in:  GH_TOKEN GH_REPO PR RUNNER_TEMP GITHUB_OUTPUT
#          COMMENT_USER_TYPE COMMENT_USER_LOGIN COMMENT_ASSOC REPO_PRIVATE
#          GH (optional: the gh binary, so tests can substitute a stub)
set -euo pipefail

GH="${GH:-gh}"
MAX_REPLIES_PER_HOUR="${MAX_REPLIES_PER_HOUR:-6}"
: "${PR:?}" "${GH_REPO:?}" "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}"

no()  { echo "answer=false" >> "$GITHUB_OUTPUT"; echo "::notice::$*"; exit 0; }

# 1. Never answer a bot, whatever the caller or the job `if` let through.
login="${COMMENT_USER_LOGIN:-}"
case "${COMMENT_USER_TYPE:-}" in Bot) no "Comment is from a bot ($login); not answering." ;; esac
case "$login" in
  ''|claude|github-actions|*'[bot]') no "Comment author '$login' is not a person; not answering." ;;
esac

# 2. On a public repository anyone can comment. Only people with a standing relationship
# to the repo get a model call. Private repos skip this: everyone who can comment there is
# already one of ours, and GitHub reports a member whose membership is private as NONE —
# filtering on it there would bring back the silence bug for exactly those developers.
# An EMPTY value reads as private for the same reason: GitHub always sends the field, and
# of the two ways to be wrong, silence for our own developers is the one that has bitten.
if [ "${REPO_PRIVATE:-true}" != "true" ]; then
  case "${COMMENT_ASSOC:-NONE}" in
    OWNER|MEMBER|COLLABORATOR|CONTRIBUTOR) ;;
    *) no "Public repository and commenter association is '${COMMENT_ASSOC:-NONE}'; not answering." ;;
  esac
fi

# One API read; everything below is decided from it.
#
# `statusCheckRollup` needs `checks: read`, which older callers do not grant. GitHub then
# fails the WHOLE query, not just that field, and `set -e` used to kill the job — which is
# how two developers were left without an answer on 16-17 Sep 2026. So: ask for it, and
# fall back to the same query without it.
fields=state,isDraft,headRefOid,baseRefName,reviews,comments,headRepositoryOwner,headRepository
checks_read=true
if ! "$GH" pr view "$PR" --json "$fields,statusCheckRollup" > "$RUNNER_TEMP/pr.json" 2>"$RUNNER_TEMP/pr.err"; then
  echo "::notice::Could not read status checks ($(tr -d '\n' < "$RUNNER_TEMP/pr.err")); continuing without them."
  "$GH" pr view "$PR" --json "$fields" > "$RUNNER_TEMP/pr.json"
  checks_read=false
fi

state=$(jq -r .state       "$RUNNER_TEMP/pr.json")
draft=$(jq -r .isDraft     "$RUNNER_TEMP/pr.json")
head=$(jq  -r .headRefOid  "$RUNNER_TEMP/pr.json")
base=$(jq  -r .baseRefName "$RUNNER_TEMP/pr.json")

# 3. Circuit breaker. If the loop guards above ever fail, this is what stops a runaway
# from draining the subscription: count our own comments on this PR in the last hour.
recent=$(jq -r --argjson max_age 3600 '[.comments[]?
  | select((.author.login // "") | test("^(claude|github-actions)(\\[bot\\])?$"))
  | select(((.createdAt // "") | (fromdateiso8601? // 0)) > (now - $max_age))] | length' \
  "$RUNNER_TEMP/pr.json")
if [ "$recent" -gt "$MAX_REPLIES_PER_HOUR" ]; then
  no "Circuit breaker: $recent automated comments on this PR in the last hour (limit $MAX_REPLIES_PER_HOUR); not answering."
fi

# 4. Fork guard. Without this, anyone who can comment on a fork PR gets this job to check
# out their branch with a token in scope.
headrepo="$(jq -r '((.headRepositoryOwner.login // "") + "/" + (.headRepository.name // ""))' "$RUNNER_TEMP/pr.json")"
if [ "$headrepo" != "$GH_REPO" ]; then
  no "Fork pull request ($headrepo); not answering."
fi

# The reviewer's own most recent STANDING verdict, and the commit it was given on. It
# posts as `claude` or `claude[bot]`. A dismissed review is not a verdict — but it is a
# ruling: when every verdict it gave here was dismissed (by a person, or by
# approval-guard.sh / respond-withdraw.sh — GitHub does not say who), verdict=DISMISSED,
# so the conversation goes on instead of a false "no review on record".
bot_reviews='[.reviews[]? | select((.author.login // "") | sub("\\[bot\\]$";"") == "claude")]'
# a COMMENTED review starting with the needs-human marker is a verdict too: NEEDS_HUMAN
last_verdict="$bot_reviews | map(select(.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\"
  or (.state == \"COMMENTED\" and ((.body // \"\") | startswith(\"<!-- pr-reviewer:needs-human -->\"))))) | last"
verdict=$(jq -r "$last_verdict | if .state == \"COMMENTED\" then \"NEEDS_HUMAN\" else (.state // \"none\") end" "$RUNNER_TEMP/pr.json")
reviewed_sha=$(jq -r "$last_verdict | .commit.oid // \"\"" "$RUNNER_TEMP/pr.json")
if [ "$verdict" = none ] && [ "$(jq -r "$bot_reviews | map(select(.state == \"DISMISSED\")) | length" "$RUNNER_TEMP/pr.json")" -gt 0 ]; then
  verdict=DISMISSED
fi

# Did OUR build job pass on this head? Matched by provenance, not by a bare name: a check
# run from this same caller workflow (WORKFLOW_NAME = github.workflow), whose job is
# `build` — GitHub names it `<caller job> / build`, e.g. `pr-review / build`; the bare
# `build` this used to look for never matched a real caller. Another workflow's `build`
# never counts. Re-runs: the newest start wins; two different results started at the
# same moment is `unknown`, never the nicer of the two.
#   success | failure | cancelled | … (GitHub's conclusion, lower-cased for the prompt)
#   pending    still running        unknown  no such check, or ambiguous
#   unreadable this job may not read checks (no `checks: read`) — a setup gap, not a red build
if [ "$checks_read" = false ]; then
  build=unreadable
else
  build=$(jq -r --arg wf "${WORKFLOW_NAME:-}" '
    [.statusCheckRollup[]?
      | select((.__typename // "CheckRun") == "CheckRun")
      | select($wf != "" and (.workflowName // "") == $wf)
      | select(.name == "build" or ((.name // "") | endswith(" / build")))]
    | if length == 0 then "unknown"
      # a re-run still queued has no start time yet: it outranks any finished attempt
      elif any(.[]; (.status // "COMPLETED") != "COMPLETED") then "pending" else
        (max_by(.startedAt // "") | .startedAt // "") as $t
        | [.[] | select((.startedAt // "") == $t)] as $newest
        | if ([$newest[] | [.status, .conclusion]] | unique | length) > 1 then "unknown"
          elif ($newest[0].status // "COMPLETED") != "COMPLETED" then "pending"
          else ($newest[0].conclusion // "unknown" | ascii_downcase) end
      end' "$RUNNER_TEMP/pr.json")
fi

echo "state=$state draft=$draft verdict=$verdict reviewed=$reviewed_sha build=$build"
{
  echo "head=$head"
  echo "base=$base"
  echo "build=$build"
  echo "verdict=$verdict"
  echo "reviewed_sha=$reviewed_sha"
} >> "$GITHUB_OUTPUT"

# 5. Answer on any open, non-draft PR this reviewer has already ruled on, blocking or not.
# A question asked after an approval deserves an answer too, and an approval that turns
# out to be wrong has to be withdrawable.
if [ "$state" = OPEN ] && [ "$draft" = false ] \
   && { [ "$verdict" = CHANGES_REQUESTED ] || [ "$verdict" = APPROVED ] || [ "$verdict" = DISMISSED ] \
        || [ "$verdict" = NEEDS_HUMAN ]; }; then
  echo "answer=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "answer=false" >> "$GITHUB_OUTPUT"
echo "::notice::Not adjudicating (state=$state draft=$draft last verdict=$verdict)."

# No verdict on record: the PR was open before the reviewer reached this repo, or its
# review never ran. Silence reads as "the bot is broken", so say it once, with no model
# call, and say how to get a review.
if [ "$state" = OPEN ] && [ "$draft" = false ] && [ "$verdict" = none ]; then
  marker='<!-- pr-reviewer:no-verdict -->'
  have=$(jq -r --arg m "$marker" '[.comments[]?.body | select(contains($m))] | length' "$RUNNER_TEMP/pr.json")
  if [ "$have" = 0 ]; then
    "$GH" pr comment "$PR" --body "$(printf '%s\n\n%s\n\n%s\n' "$marker" \
      "🤖 **No review on record for this pull request** — so there is nothing here for me to answer." \
      "I review a pull request when it is opened or pushed to, and this one was already open before I reached this repository. Push any commit to the branch, or close and reopen the PR, and I will build it and post a full review.")" \
      || echo "::warning::Could not post the no-verdict note."   # cosmetic: never turn the check red over it
  fi
fi
