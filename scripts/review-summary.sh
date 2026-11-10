#!/usr/bin/env bash
# review-summary.sh — boil the reviewer's record of the run down to the few facts that
# explain a run that ended without a verdict, and write ONLY those to OUT.
#
# The record itself (claude-code-action's execution file) is never kept: it holds every
# tool result, so the full text of each file the reviewer opened, consumer repositories
# included. Those are read with a token for repos the readers of this run may not be able
# to see (pr-reviewer#26 review, 14 Oct 2026). What is kept is derived, never copied:
#   turns_used, max_turns, outcome (the result subtype), is_error,
#   result        the reviewer's final message, cut to 1000 characters (the same text it
#                 would post on the PR; it is not a tool result)
#   refused_count, refused[]  {tool, input}: the command / path / pattern / URL the
#                 reviewer was refused, first line only (a heredoc body never survives),
#                 cut to 200 characters; tools whose input is file content (Write, Edit)
#                 keep only the path. At most 50.
#   verdict_posted  null here; verdict-check.sh fills it in.
#
# No record, or one with no `result` message → no summary is written, and verdict-check.sh
# keeps its older wording. Always exits 0: this explains a run, it never fails one.
#
# Env in: EXEC_FILE (the execution file) OUT (where the summary goes) TURNS (the budget)
set -uo pipefail

: "${OUT:?}"
rm -f "$OUT"
if [ -z "${EXEC_FILE:-}" ] || [ ! -s "$EXEC_FILE" ]; then
  echo "No record of the run at ${EXEC_FILE:-<unset>} — no summary."
  exit 0
fi

# The file is a JSON array of messages, or one message per line. The last `result` message
# carries the turn count and every refused action.
jq -cs --arg turns "${TURNS:-}" '
  def clip($n): if length > $n then .[:$n] + " …" else . end;
  def what: (.command // .file_path // .path // .notebook_path // .pattern // .url // .query // "")
            | tostring
            | (split("\n") | if length > 1 then .[0] + " …" else (.[0] // "") end)
            | gsub("[\\r\\t]"; " ")
            | clip(200);
  (if length == 1 and (.[0] | type) == "array" then .[0] else . end
   | map(select(type == "object" and .type == "result")) | last) as $r
  | if $r == null then empty else
    { turns_used:     ($r.num_turns // null),
      max_turns:      ($turns | tonumber? // null),
      outcome:        ($r.subtype // null),
      is_error:       $r.is_error,
      verdict_posted: null,
      result:         (($r.result // "") | tostring | clip(1000)),
      refused_count:  (($r.permission_denials // []) | length),
      refused:        [ ($r.permission_denials // [])[:50][]
                        | { tool: ((.tool_name // "?") | tostring | .[:60]),
                            input: ((.tool_input // {}) | if type == "object" then what else "" end) } ] }
    end' "$EXEC_FILE" > "$OUT.tmp" 2>/dev/null || { rm -f "$OUT.tmp"; echo "Record unreadable — no summary."; exit 0; }

if [ -s "$OUT.tmp" ]; then
  mv "$OUT.tmp" "$OUT"
  echo "Summary written to $OUT: $(jq -c '{turns_used, max_turns, outcome, refused_count}' "$OUT")"
else
  rm -f "$OUT.tmp"
  echo "Record has no result message — no summary."
fi
exit 0
