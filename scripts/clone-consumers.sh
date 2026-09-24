#!/usr/bin/env bash
# clone-consumers.sh — check out the repositories consumers.sh listed, read-only, BEFORE
# the model runs, then revoke the tokens that did it.
#
# The token (from the read-only GitHub App "designblue-pr-reviewer-read": Contents + Metadata
# read, nothing else) is only ever in this step's environment. It is passed to git as a
# one-command header (`-c http.…extraheader`), so it is written to no .git/config; each
# checkout's .git is then deleted, and the token revoked, before the Review step starts.
# What the model gets is plain files and a manifest line per repository.
#
# Never fails the job: a repo that cannot be cloned is named in the manifest as not read,
# so the review falls back to "needs a human" for it, as before.
#
# Env in:  LIST (owner/repo[@ref] per line)  DEST (where to put them)
#          TOKEN_MANILA TOKEN_CREATE (installation tokens; empty = none for that account)
#          GIT_BASE (optional, default https://github.com — tests point it at local repos)
#          API (optional, default https://api.github.com; empty = do not revoke)
# Out ($GITHUB_OUTPUT): manifest — one line per repository, for the prompt
set -uo pipefail

: "${LIST:?}" "${DEST:?}"
GIT_BASE="${GIT_BASE:-https://github.com}"
API="${API-https://api.github.com}"
export GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1

revoke() {
  [ -n "$API" ] || return 0
  local t
  for t in "${TOKEN_MANILA:-}" "${TOKEN_CREATE:-}"; do
    [ -n "$t" ] && curl -fsS -X DELETE -H "Authorization: Bearer $t" "$API/installation/token" >/dev/null 2>&1 || true
  done
}
trap revoke EXIT

mkdir -p "$DEST"
manifest=""
add() { manifest="${manifest:+$manifest
}$1"; }

while IFS= read -r item; do
  [ -n "$item" ] || continue
  owner="${item%%/*}" rest="${item#*/}"
  repo="${rest%%@*}" ref=""
  [ "$rest" != "$repo" ] && ref="${rest#*@}"
  case "$owner" in
    Designblue-Manila)       tok="${TOKEN_MANILA:-}" ;;
    designbluemanila-create) tok="${TOKEN_CREATE:-}" ;;
    *) add "- $owner/$repo: NOT READ (account not allowed)"; continue ;;
  esac
  if [ -z "$tok" ]; then
    add "- $owner/$repo: NOT READ (no read token for $owner: the key may be wrong, the app not installed on one of the listed repos, or one of them renamed or deleted)"
    continue
  fi
  dir="$DEST/$owner/$repo"
  rm -rf "$dir"; mkdir -p "$(dirname "$dir")"
  auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')"
  if git -c "http.https://github.com/.extraheader=$auth" -c protocol.file.allow="${ALLOW_FILE_PROTOCOL:-never}" \
       clone --quiet --depth 1 --single-branch --no-tags ${ref:+--branch "$ref"} \
       -- "$GIT_BASE/$owner/$repo.git" "$dir" 2> "$DEST/.clone.err"; then
    sha="$(git -C "$dir" rev-parse --short=12 HEAD)"
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    rm -rf "$dir/.git"
    add "- $owner/$repo @ $branch ($sha): $dir"
    echo "Checked out $owner/$repo @ $branch ($sha)."
  else
    rm -rf "$dir"
    why="$(grep -m1 -E 'fatal|error' "$DEST/.clone.err" | sed 's/[[:space:]]\{1,\}/ /g' | cut -c1-120)"
    echo "::warning::Could not check out $owner/$repo${ref:+@$ref}: ${why:-unknown error}"
    add "- $owner/$repo${ref:+@$ref}: NOT READ (clone failed${why:+: $why})"
  fi
done <<< "$LIST"
rm -f "$DEST/.clone.err"

{ echo "manifest<<MANIFEST_EOF"; printf '%s\n' "$manifest"; echo "MANIFEST_EOF"; } >> "${GITHUB_OUTPUT:-/dev/null}"
