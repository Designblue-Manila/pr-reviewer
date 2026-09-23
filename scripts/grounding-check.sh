#!/usr/bin/env bash
# grounding-check.sh — hold what the bot POSTED to the evidence, not just its verdict.
#
# Runs after the model, inside the PR checkout. Deterministic: no model call. Two checks,
# on everything the bot (claude / claude[bot]) posted during this run — review bodies and
# inline findings (review job), or reply comments (respond job):
#
#   1. Every file it cites must exist — in this checkout, or in the PR's file list (a file
#      the PR deleted or renamed away is a real reference). A model that cannot find a
#      location can invent one: in the 23 Sep evaluation a withdrawal named
#      app/Http/Controllers/OrderController.php, which was in no evidence at all. Posted
#      text cannot be edited by the model or by this script, so it adds ONE comment per
#      run naming every reference it could not find.
#   2. An approval of this commit on a repo with `tests=none` must say there are no tests
#      (REVIEW-STANDARDS.md: "safe" then means it builds and every consumer was read).
#      In the evaluation all three safe no-test approvals left that out. Missing → added.
#
# What counts as a file reference is deliberately narrow — a false note teaches people to
# ignore the real ones: a token with a letter extension that has a `/` in it or a `:line`
# after it; URLs dropped; `vendor/` and `node_modules/` skipped; a path whose first folder
# is not at the top of this repo skipped (a hostname, a package import). `~/` and `@/`
# (Nuxt aliases) are always checked, as written and under app/ and src/. A shortened path
# counts when a real file's path ends with it.
#
# A quality note, never a gate: it always exits 0. Unreadable API → a warning.
#
# Env in: GH_TOKEN REPO PR HEAD_SHA SINCE (ISO 8601 UTC) MODE (review|reply)
#         RUN_KEY (one note per run; the workflow passes run id + attempt)
#         SUMMARY_FILE (the build summary; review mode)
#         GH (optional: the gh binary, so tests can substitute a stub)
set -uo pipefail

GH="${GH:-gh}"
: "${REPO:?}" "${PR:?}" "${HEAD_SHA:?}" "${SINCE:?}"
MODE="${MODE:-review}"
RUN_KEY="${RUN_KEY:-$HEAD_SHA}"
T="${RUNNER_TEMP:-/tmp}"
bot='select(((.user.login // "") | sub("\\[bot\\]$"; "")) == "claude")'
warn() { echo "::warning::$*"; exit 0; }

# what the bot posted this run: one JSON object per line. Each read goes to its own file,
# so a failed one can never leave half an error message in the data.
since_created="select((.created_at // \"\") >= \"$SINCE\")"
: > "$T/posted.jsonl"
if [ "$MODE" = reply ]; then
  "$GH" api "repos/$REPO/issues/$PR/comments" --paginate \
    --jq ".[] | $bot | $since_created | {body: (.body // \"\")} | @json" > "$T/part.jsonl" 2>/dev/null \
    || warn "Could not read this PR's comments; grounding not checked."
  cat "$T/part.jsonl" >> "$T/posted.jsonl"
else
  "$GH" api "repos/$REPO/pulls/$PR/reviews" --paginate \
    --jq ".[] | $bot | select((.submitted_at // \"\") >= \"$SINCE\") | {state, commit_id, body: (.body // \"\")} | @json" \
    > "$T/part.jsonl" 2>/dev/null || warn "Could not read this PR's reviews; grounding not checked."
  cat "$T/part.jsonl" >> "$T/posted.jsonl"
  # inline findings (create_inline_comment): where most Important items actually go
  if "$GH" api "repos/$REPO/pulls/$PR/comments" --paginate \
       --jq ".[] | $bot | $since_created | {body: (.body // \"\")} | @json" > "$T/part.jsonl" 2>/dev/null; then
    cat "$T/part.jsonl" >> "$T/posted.jsonl"
  else
    echo "::warning::Could not read inline comments; only review bodies checked."
  fi
fi
[ -s "$T/posted.jsonl" ] || { echo "Nothing posted by the reviewer in this run."; exit 0; }

# every path that counts as real: the checkout's files plus the PR's own list, old names too
{ if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git ls-files
  else find . \( -name .git -o -name node_modules -o -name vendor \) -prune -o -type f -print | sed 's#^\./##'; fi
  "$GH" api "repos/$REPO/pulls/$PR/files" --paginate --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null
} | sort -u > "$T/known-files.txt"
"$GH" api "repos/$REPO/issues/$PR/comments" --paginate --jq '.[].body // ""' > "$T/all-comments.txt" 2>/dev/null \
  || : > "$T/all-comments.txt"

say() { # marker body -> one comment, once per marker
  grep -qF "$1" "$T/all-comments.txt" && { echo "Already noted ($1)."; return; }
  printf '%s\n\n%s\n' "$1" "$2" > "$T/grounding.md"
  printf '%s\n' "$1" >> "$T/all-comments.txt"
  "$GH" pr comment "$PR" --repo "$REPO" --body-file "$T/grounding.md" || echo "::warning::Could not post the note."
}

# 1. references that exist nowhere (kept as a variable: bash 3.2 mis-parses a heredoc in $(...))
read -r -d '' MISSING_PY <<'PY' || true
import json,re,sys
known=[l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
known_set=set(known); top={k.split("/")[0] for k in known}
def exists(p):
    return p in known_set or any(k.endswith("/"+p) for k in known)
missing=[]
for line in open(sys.argv[2]):
    try: body=json.loads(line).get("body") or ""
    except Exception: continue
    body=re.sub(r"[A-Za-z][\w+.-]*://\S+","",body)
    body=body.replace("…/","").replace(".../","")
    # a segment may hold & + = $ and [ ] (Nuxt's [slug].vue): a split name is a false note
    # A path starts with a name character or a WHOLE bracket group (Nuxt's `[slug].vue`,
    # `[...slug].vue`) — never a bare `[`, so a markdown link `[Foo.php:12](…)` is read from
    # the letter on. `=` is not a name character (`path=app/x.php` is read from `app`).
    # `-` is last in each class, so never a range.
    first=r"(?:\[[\w.]+\]|[\w@.&$-])"; seg=r"[\w@.&+$\[\]-]"; before=r"[\w@.&$/~-]"
    for m in re.finditer(r"(?<!"+before+r")((?:[~@]/)?"+first+seg+r"*(?:/"+seg+r"+)*\.[A-Za-z][A-Za-z0-9]{0,7})(:\d+)?", body):
        p,ln=m.group(1),m.group(2)
        aliased=p.startswith(("~/","@/"))
        p=p[2:] if aliased else p
        while p.startswith("./"): p=p[2:]
        if not ("/" in p or ln): continue
        if p.startswith(("vendor/","node_modules/",".pr-reviewer/",".build-results/")): continue
        if aliased:
            if exists(p) or exists("app/"+p) or exists("src/"+p): continue
        else:
            # a hostname or a package import. Price, accepted: an invented top-level folder
            # (`src/x.php` in a repo with no src/) is not flagged; `app/…` in a Laravel repo is.
            if "/" in p and p.split("/")[0] not in top: continue
            if exists(p): continue
        if p not in missing: missing.append(p)
for p in missing: print(p)
PY
# a failure here skips only this check, never the no-tests one below
missing="$(python3 -c "$MISSING_PY" "$T/known-files.txt" "$T/posted.jsonl" 2>"$T/grounding.err")" \
  || { echo "::warning::File references not checked: $(tail -1 "$T/grounding.err")"; missing=""; }
if [ -n "$missing" ]; then
  list="$(printf '%s\n' "$missing" | sed 's/.*/- `&`/')"
  echo "::warning::The reviewer cited files that do not exist here: $(printf '%s' "$missing" | tr '\n' ' ')"
  say "<!-- pr-reviewer:grounding:$RUN_KEY -->" "$(printf '🤖 **Check on my comments above:** they refer to\n%s\nwhich I cannot find in this repository at %s or in this PR'"'"'s files. Treat those lines as unverified; the findings they belong to still have to be judged on the code.' "$list" "${HEAD_SHA:0:7}")"
fi

# 2. the no-tests disclosure on an approval of this commit
if [ "$MODE" = review ] && [ -f "${SUMMARY_FILE:-}" ]; then
  untested="$(grep -E '(^| )tests=none( |$)' "$SUMMARY_FILE" | grep -oE 'project=[^ ]+' | cut -d= -f2 | paste -sd, - | sed 's/,/, /g')"
  approved="$(jq -rR --arg h "$HEAD_SHA" 'fromjson? | select(.state == "APPROVED" and .commit_id == $h) | .body' "$T/posted.jsonl" 2>/dev/null | tr '\n' ' ')"
  said='no (automated )?tests in (this|the) (repo|repository|project)|build only|(repo|repository|project) has no (automated )?tests'
  if [ -n "$untested" ] && [ -n "$approved" ] && ! printf '%s' "$approved" | grep -qiE "$said"; then
    [ "$untested" = . ] && where="This repository" || where="Project(s) $untested"
    say "<!-- pr-reviewer:no-tests:$HEAD_SHA -->" "🤖 **Note on the approval above:** $where has no automated tests, so \"safe to merge\" here means it builds and every consumer of the change was read and judged — not that its behaviour was tested."
  fi
fi
exit 0
