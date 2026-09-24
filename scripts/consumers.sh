#!/usr/bin/env bash
# consumers.sh — which OTHER repositories use this one, read from the BASE branch.
#
# Step 4 of the review ("cross-repo impact") used to end at "a breaking change you cannot
# settle → needs a human", because the reviewer could only see this repository. A repo can
# now name its consumers in `.github/REVIEW-NOTES.md`:
#
#     ## Consumers
#     - Designblue-Manila/brikk-inventory-v2 — calls /api/transfers
#     - designbluemanila-create/kaimana-siargao-site@staging
#
# and the review job checks those out read-only BEFORE the model runs (clone-consumers.sh),
# with a short-lived token from the read-only GitHub App. The model never sees the token.
#
# Read from the DEFAULT branch, never the PR head and not the PR's base either: a pull
# request must not choose which repositories its own review reads, and anyone with write
# access can create a branch, put a list on it, and open a PR INTO it. The default branch
# is the one that is protected and reviewed. A new list takes effect once merged there.
#
# Deterministic, no model call. Never fails the job: a list it cannot read is a warning,
# and the review goes on exactly as before, from this repository alone.
#
# Env in:  REPO NOTES_REF (the default branch) HAS_KEY (true when the repo has PR_REVIEWER_APP_KEY)
#          GH (optional: the gh binary, so tests can substitute a stub)
# Out ($GITHUB_OUTPUT):
#   list    owner/repo[@ref], one per line — only when there is a key to read them with
#   manila  comma-separated repo names under Designblue-Manila      (for the token scope)
#   create  comma-separated repo names under designbluemanila-create
#   note    one line for the prompt when nothing will be checked out, saying why
set -uo pipefail

GH="${GH:-gh}"
: "${REPO:?}" "${NOTES_REF:?}"
HAS_KEY="${HAS_KEY:-false}"
MAX=5                         # each one is a clone and model turns; a longer list is a smell
T="${RUNNER_TEMP:-/tmp}"
out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

if ! "$GH" api "repos/$REPO/contents/.github/REVIEW-NOTES.md?ref=$NOTES_REF" \
     -H "Accept: application/vnd.github.raw" > "$T/review-notes.md" 2> "$T/review-notes.err"; then
  if grep -q "404" "$T/review-notes.err"; then
    out note "none listed (no .github/REVIEW-NOTES.md on $NOTES_REF)"
  else
    echo "::warning::Could not read .github/REVIEW-NOTES.md from $NOTES_REF; consumers not checked out."
    out note "unknown (the consumer list could not be read)"
  fi
  exit 0
fi

# the `## Consumers` section, up to the next heading. Only list items that are a plain
# owner/repo[@ref] in one of our two accounts count; anything else is ignored, and said so.
list="" ignored=0 n=0
in=0
while IFS= read -r line || [ -n "$line" ]; do
  if printf '%s' "$line" | grep -qiE '^#{1,3}[[:space:]]'; then
    if printf '%s' "$line" | grep -qiE '^#{2,3}[[:space:]]+consumers[[:space:]]*$'; then in=1; else in=0; fi
    continue
  fi
  [ "$in" = 1 ] || continue
  printf '%s' "$line" | grep -qE '^[[:space:]]*[-*][[:space:]]' || continue
  item="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*][[:space:]]+`?//; s/[`[:space:]].*$//')"
  if ! printf '%s' "$item" | grep -qE '^[A-Za-z0-9-]+/[A-Za-z0-9][A-Za-z0-9._-]*(@[A-Za-z0-9][A-Za-z0-9._/-]*)?$' \
     || printf '%s' "$item" | grep -q '\.\.'; then
    ignored=$((ignored+1)); continue
  fi
  owner="${item%%/*}" rest="${item#*/}"
  case "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" in
    designblue-manila)       owner=Designblue-Manila ;;
    designbluemanila-create) owner=designbluemanila-create ;;
    *) ignored=$((ignored+1)); continue ;;    # the app is installed on our two accounts only
  esac
  repo="${rest%%@*}"
  [ "$(printf '%s' "$owner/$repo" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ] && continue
  # one checkout per repository: a second line for it (another @branch) would overwrite the first
  printf '%s\n' "$list" | sed 's/@.*//' | grep -qixF "$owner/$repo" && continue
  if [ "$n" -ge "$MAX" ]; then
    echo "::warning::More than $MAX consumers listed; only the first $MAX are checked out."; break
  fi
  list="${list:+$list
}$owner/$rest"; n=$((n+1))
done < "$T/review-notes.md"
[ "$ignored" -gt 0 ] && echo "::warning::$ignored line(s) under '## Consumers' ignored: each must be owner/repo[@branch] in Designblue-Manila or designbluemanila-create."

if [ -z "$list" ]; then
  out note "none listed (no '## Consumers' section in .github/REVIEW-NOTES.md on $NOTES_REF)"; exit 0
fi
if [ "$HAS_KEY" != true ]; then
  out note "listed but NOT checked out — this repository has no PR_REVIEWER_APP_KEY secret: $(printf '%s' "$list" | paste -sd, - | sed 's/,/, /g')"
  exit 0
fi

# LC_ALL=C: byte order, the same on every machine (a Linux runner's locale sorts case-insensitively).
names() { printf '%s\n' "$list" | grep "^$1/" | sed -E "s#^$1/##; s#@.*##" | LC_ALL=C sort -u | paste -sd, -; }
{ echo "list<<CONSUMERS_EOF"; printf '%s\n' "$list"; echo "CONSUMERS_EOF"; } >> "${GITHUB_OUTPUT:-/dev/null}"
out manila "$(names Designblue-Manila)"
out create "$(names designbluemanila-create)"
echo "Consumers to check out:"; printf '%s\n' "$list" | sed 's/^/  /'
