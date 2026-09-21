#!/usr/bin/env bash
# release.sh — check that a commit is safe to release, then PRINT the tag commands.
#
#   scripts/release.sh canary [commit]    move v2-canary (the two canary repos only)
#   scripts/release.sh fleet  [commit]    move v2 and v1 (every repo)
#   scripts/release.sh status             where every release tag points, local and remote
#
# It never pushes. Moving a release tag is a forced push to a repo every project depends
# on, and that stays a person's decision: this script does the checking and hands over
# the exact commands, in the order they must run. `commit` defaults to origin/main.
#
# What it refuses, and why:
#   - a commit that is not on origin/main          unreviewed work must not reach the fleet
#   - a commit whose review.yml does not gate       thin callers carry no filter of their own. On
#     itself (the FLOOR)                            an older, ungated review.yml a thin caller answers
#                                                   its own comments in a loop, on one person's
#                                                   subscription. Judged by CONTENT, with today's
#                                                   checker, so it holds for ROLLBACKS too: you can
#                                                   roll back as far as the first gated commit, never
#                                                   past it.
#   - a commit whose own checks fail                tests, actionlint
#   - `fleet` for a commit the canary never ran     the canary exists so the fleet is not the test
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANARY_TAG=v2-canary
FLEET_TAGS="v1 v2"                           # v1 first: see "Order" below

die()  { printf '\nREFUSED: %s\n' "$*" >&2; exit 1; }
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
# The COMMIT a remote tag points at. An annotated tag lists twice — the tag object, then
# the peeled `^{}` commit — and only the second can ever equal a commit SHA; `tail -1`
# takes it when it is there and the plain line when the tag is lightweight.
remote_tag() { git -C "$ROOT" ls-remote --tags origin "refs/tags/$1" "refs/tags/$1^{}" | tail -1 | cut -f1; }
tag_commands() { # tag, commit
  printf '  git tag -f %s %s\n' "$1" "$2"
  printf '  git push -f origin %s\n' "$1"
}

mode="${1:-}"; target_ref="${2:-origin/main}"
case "$mode" in canary|fleet|status) ;; *) sed -n '2,8p' "$0"; exit 2 ;; esac

git -C "$ROOT" fetch --quiet origin || die "could not fetch origin"

if [ "$mode" = status ]; then
  say "Release tags (remote)"
  for t in $CANARY_TAG $FLEET_TAGS; do
    sha="$(remote_tag "$t")"; printf '  %-10s %s\n' "$t" "${sha:0:12}"
  done
  printf '  %-10s %s\n' main "$(git -C "$ROOT" rev-parse --short=12 origin/main)"
  exit 0
fi

target="$(git -C "$ROOT" rev-parse --verify --quiet "$target_ref^{commit}")" || die "unknown commit: $target_ref"
say "Releasing $(git -C "$ROOT" log -1 --format='%h %s' "$target") -> $mode"

git -C "$ROOT" merge-base --is-ancestor "$target" origin/main \
  || die "$target_ref is not on origin/main. Merge it first; only reviewed work is released."

# Check the commit being released, not whatever happens to be in the working tree.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
git -C "$ROOT" archive "$target" | tar -x -C "$work" || die "could not export $target"
# The contract check is TODAY's checker run on THAT commit's files: an old commit's own
# checker knows nothing about gates and would wave an ungated review.yml through.
# What makes this a floor is the checker's own rules — mandatory clauses, no extra `||`,
# permissions within the field's grants. The golden file is the TARGET's, so it proves only
# that the commit is consistent with itself; it is not what stops a weakened gate.
# "Today's checker" has to mean the reviewed one, not an edited copy on this machine:
[ -z "$(git -C "$ROOT" status --porcelain -- scripts/check-caller-contract.py)" ] \
  || die "scripts/check-caller-contract.py has uncommitted changes. The floor is judged with it; commit or stash first."
command -v actionlint >/dev/null \
  || die "actionlint is not installed. A release is not printed without it (brew install actionlint)."
python3 "$ROOT/scripts/check-caller-contract.py" \
    "$work/.github/workflows/review.yml" "$work/caller-template.yml" "$work/tests/gates.golden" \
  || die "that commit's review.yml does not gate itself (or breaks the caller contract). Thin callers would loop on it — this is the release floor."
( cd "$work" && bash tests/run.sh >/dev/null ) || die "tests/run.sh fails at that commit (run it to see which)"
( cd "$work" && actionlint -ignore 'property "workflow_sha" is not defined' .github/workflows/review.yml ) \
  || die "actionlint fails at that commit"

if [ "$mode" = canary ]; then
  say "Checks pass. Run this, then reopen the standing test PR in each canary repo:"
  tag_commands "$CANARY_TAG" "$target"
  printf '\nExpect, in BOTH repos: build + review checks appear, the review requests changes and\n'
  printf 'names the planted defect. Then: scripts/release.sh fleet %s\n' "${target:0:12}"
  exit 0
fi

# fleet
canary="$(remote_tag "$CANARY_TAG")"
[ "$canary" = "$target" ] || die "$CANARY_TAG is at ${canary:0:12}, not ${target:0:12}. Release to the canary first and watch it work."

say "Checks pass and the canary ran this commit. Run these IN THIS ORDER, one at a time:"
for t in $FLEET_TAGS; do tag_commands "$t" "$target"; done
cat <<NOTE

Order: v1 before v2. review.yml fetches its scripts at its own commit, and falls back to the
v1 tag if GitHub does not say which commit that is. v1 first means that in the seconds between
the two pushes nothing can run a NEW workflow against OLD scripts; both must end on one commit.
Afterwards:  scripts/release.sh status     (v1, v2 and $CANARY_TAG must all show ${target:0:12})
Rollback:    scripts/release.sh fleet <last good commit> — it refuses anything below the floor.
NOTE
