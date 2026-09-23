#!/usr/bin/env bash
# Offline tests for the two deterministic scripts and for the contract checker itself.
#   tests/run.sh        exits 1 on the first group with a failure, prints every result
# No network, no GitHub: `gh` is tests/gh-stub. Needs bash, jq, python3.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
export GH="$HERE/gh-stub"
pass=0 fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

fresh() {
  STUB_DIR="$(mktemp -d)"; export STUB_DIR STUB_LOG="$STUB_DIR/calls.log"
  export RUNNER_TEMP="$STUB_DIR/tmp" GITHUB_OUTPUT="$STUB_DIR/output"
  mkdir -p "$RUNNER_TEMP"; : > "$STUB_LOG"; : > "$GITHUB_OUTPUT"
}
out()    { grep -E "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }
calls()  { grep -c "$1" "$STUB_LOG" || true; }
posted() { local n=0 f; for f in "$STUB_DIR"/posted.*; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }
iso_ago() { # seconds ago -> ISO 8601 UTC, BSD or GNU date
  date -u -v-"$1"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# pr.json builder: state draft verdict-state headrepo-owner headrepo-name [comments-json] [checks-json]
pr_json() {
  local reviews='[]'
  [ "$3" != none ] && reviews="[{\"author\":{\"login\":\"claude\"},\"state\":\"$3\",\"commit\":{\"oid\":\"${REVIEWED:-abc123}\"}}]"
  jq -n --arg state "$1" --argjson draft "$2" --argjson reviews "$reviews" --arg o "$4" --arg n "$5" \
        --argjson comments "${6:-[]}" --argjson checks "${7:-[]}" \
    '{state:$state,isDraft:$draft,headRefOid:"abc123",baseRefName:"main",reviews:$reviews,
      comments:$comments,statusCheckRollup:$checks,
      headRepositoryOwner:{login:$o},headRepository:{name:$n}}' > "$STUB_DIR/pr.json"
}
gate() { # env assignments as args
  env PR=7 GH_REPO=acme/site GH_TOKEN=x REPO_PRIVATE=true COMMENT_USER_TYPE=User WORKFLOW_NAME="PR Review" \
      COMMENT_USER_LOGIN=camile COMMENT_ASSOC=MEMBER "$@" \
      bash "$ROOT/scripts/respond-gate.sh" > "$STUB_DIR/stdout" 2>&1
  echo $?
}

echo "respond-gate.sh"
fresh; pr_json OPEN false APPROVED acme site
rc=$(gate COMMENT_USER_TYPE=Bot COMMENT_USER_LOGIN='claude[bot]')
check "bot comment -> no answer"                 "0/false/0" "$rc/$(out answer)/$(calls .)"
fresh; pr_json OPEN false APPROVED acme site
rc=$(gate COMMENT_USER_LOGIN='claude[bot]')
check "bot login with a spoofed User type -> no answer, no API call" "0/false/0" "$rc/$(out answer)/$(calls .)"
fresh; pr_json OPEN false APPROVED acme site
rc=$(gate COMMENT_USER_LOGIN='')
check "missing login -> no answer"               "0/false" "$rc/$(out answer)"
fresh; pr_json OPEN false APPROVED acme site
rc=$(gate REPO_PRIVATE=false COMMENT_ASSOC=NONE)
check "public repo, stranger -> no answer, no API call" "0/false/0" "$rc/$(out answer)/$(calls .)"
fresh; pr_json OPEN false APPROVED acme site
rc=$(gate REPO_PRIVATE=false COMMENT_ASSOC=CONTRIBUTOR)
check "public repo, contributor -> answers"      "0/true" "$rc/$(out answer)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site
rc=$(gate COMMENT_ASSOC=NONE)
check "private repo, association NONE (private membership) -> still answers" "0/true" "$rc/$(out answer)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site; touch "$STUB_DIR/checks-denied"
rc=$(gate)
check "checks:read denied -> falls back, build=unreadable, answers (the 16-17 Sep silence bug)" \
      "0/true/unreadable/2" "$rc/$(out answer)/$(out build)/$(calls 'pr view')"
# check runs exactly as `gh pr view --json statusCheckRollup` returned them on designbluemanila-web#89
cr() { # name workflowName status conclusion startedAt
  printf '{"__typename":"CheckRun","name":"%s","workflowName":"%s","status":"%s","conclusion":"%s","startedAt":"%s"}' "$@"; }
ours_ok="$(cr 'pr-review / build' 'PR Review' COMPLETED SUCCESS 2026-09-22T03:51:36Z)"
ours_bad="$(cr 'pr-review / build' 'PR Review' COMPLETED FAILURE 2026-09-22T03:51:36Z)"
review_ok="$(cr 'pr-review / review' 'PR Review' COMPLETED SUCCESS 2026-09-22T03:53:28Z)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$ours_ok,$review_ok]"
rc=$(gate)
check "the real check name 'pr-review / build' is found, lower-cased for the prompt (D12)" "0/true/success/CHANGES_REQUESTED" \
      "$rc/$(out answer)/$(out build)/$(out verdict)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$(cr build 'Other CI' COMPLETED SUCCESS 2026-09-22T03:50:00Z)]"
gate >/dev/null
check "another workflow's 'build' cannot stand in for ours (D03)" "unknown" "$(out build)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$ours_bad,$(cr build 'Other CI' COMPLETED SUCCESS 2026-09-22T03:59:00Z)]"
gate >/dev/null
check "a later success elsewhere does not mask our failed build (D04)" "failure" "$(out build)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$ours_bad,$(cr 'pr-review / build' 'PR Review' COMPLETED SUCCESS 2026-09-22T04:10:00Z)]"
gate >/dev/null
check "a re-run of our build: the newest attempt decides, not array order" "success" "$(out build)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$(cr 'pr-review / build' 'PR Review' COMPLETED SUCCESS 2026-09-22T04:10:00Z),$ours_bad]"
gate >/dev/null
check "... and the same the other way round" "success" "$(out build)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$ours_ok,$(cr 'ci / build' 'PR Review' COMPLETED FAILURE 2026-09-22T03:51:36Z)]"
gate >/dev/null
check "two different results started at the same moment -> unknown, never the nicer one" "unknown" "$(out build)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$(cr 'pr-review / build' 'PR Review' IN_PROGRESS '' 2026-09-22T03:51:36Z)]"
gate >/dev/null
check "a build still running is pending" "pending" "$(out build)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$ours_ok,$(cr 'pr-review / build' 'PR Review' QUEUED '' '')]"
gate >/dev/null
check "a re-run still QUEUED (no start time yet) is pending, not the old success" "pending" "$(out build)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$ours_ok]"
gate WORKFLOW_NAME= >/dev/null
check "no workflow name to match against -> unknown" "unknown" "$(out build)"

# which commit the standing verdict is on, so the reply can say "that was an older commit"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$ours_ok]"
gate >/dev/null
check "the verdict's commit is reported" "abc123" "$(out reviewed_sha)"
fresh; REVIEWED=0ldsha pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$ours_ok]"
rc=$(gate)
check "verdict on an OLDER commit -> still answers, and says which commit (D01)" "0/true/0ldsha" \
      "$rc/$(out answer)/$(out reviewed_sha)"
fresh; pr_json OPEN false CHANGES_REQUESTED acme site '[]' "[$(cr 'pr-review / build' 'PR Review' COMPLETED SKIPPED 2026-09-22T03:51:36Z)]"
gate >/dev/null
check "build skipped (a repo with nothing to build) reads as skipped" "skipped" "$(out build)"
fresh; pr_json OPEN false DISMISSED acme site
rc=$(gate)
check "the bot's only verdict was withdrawn -> still answers, no false 'no review on record' (round 4 #2)" "0/true/DISMISSED/0" \
      "$rc/$(out answer)/$(out verdict)/$(posted)"
# a person dismissed the bot's latest CHANGES_REQUESTED; an older APPROVED is not "standing" again
fresh; pr_json OPEN false none acme site
jq '.reviews=[{author:{login:"claude"},state:"CHANGES_REQUESTED",commit:{oid:"abc123"}},{author:{login:"claude"},state:"DISMISSED",commit:{oid:"abc123"}}]' "$STUB_DIR/pr.json" > "$STUB_DIR/p2" && mv "$STUB_DIR/p2" "$STUB_DIR/pr.json"
gate >/dev/null
check "an earlier standing verdict is still the verdict when a later one was dismissed" "CHANGES_REQUESTED/abc123" "$(out verdict)/$(out reviewed_sha)"
fresh; pr_json OPEN false DISMISSED acme site
gate >/dev/null
check "only dismissed verdicts -> no commit is claimed as reviewed (round 5 #2)" "DISMISSED/" "$(out verdict)/$(out reviewed_sha)"
fresh; pr_json OPEN false APPROVED stranger site
rc=$(gate)
check "fork pull request -> no answer"           "0/false" "$rc/$(out answer)"
fresh; pr_json OPEN false APPROVED "" ""
rc=$(gate)
check "head repo deleted (null) -> no answer"    "0/false" "$rc/$(out answer)"
recent="$(jq -n --arg t "$(iso_ago 120)" '[range(7) | {author:{login:"claude"},createdAt:$t,body:"🤖 **Automated reply.**"}]')"
fresh; pr_json OPEN false APPROVED acme site "$recent"
rc=$(gate)
check "7 bot replies in the last hour -> circuit breaker, no answer" "0/false" "$rc/$(out answer)"
old="$(jq -n --arg t "$(iso_ago 7200)" '[range(7) | {author:{login:"claude"},createdAt:$t,body:"🤖"}]')"
fresh; pr_json OPEN false APPROVED acme site "$old"
rc=$(gate)
check "7 bot replies two hours ago -> answers"   "0/true" "$rc/$(out answer)"
humans="$(jq -n --arg t "$(iso_ago 60)" '[range(9) | {author:{login:"mark"},createdAt:$t,body:"why?"}]')"
fresh; pr_json OPEN false APPROVED acme site "$humans"
rc=$(gate)
check "9 human comments do not trip the breaker" "0/true" "$rc/$(out answer)"
bad_ts='[{"author":{"login":"claude"},"createdAt":"not-a-date","body":"x"},{"author":{"login":"claude"},"body":"y"}]'
fresh; pr_json OPEN false APPROVED acme site "$bad_ts"
rc=$(gate)
check "malformed / missing comment timestamp does not kill the gate" "0/true" "$rc/$(out answer)"
fresh; pr_json OPEN false none acme site
rc=$(gate)
check "no verdict on record -> no answer, ONE deterministic note" "0/false/1" "$rc/$(out answer)/$(posted)"
fresh; pr_json OPEN false none acme site '[{"author":{"login":"github-actions"},"createdAt":"2026-01-01T00:00:00Z","body":"<!-- pr-reviewer:no-verdict -->\nnote"}]'
rc=$(gate)
check "note already posted -> not posted again"  "0/false/0" "$rc/$(out answer)/$(posted)"
fresh; pr_json CLOSED false none acme site
rc=$(gate)
check "closed PR -> no answer, no note"          "0/false/0" "$rc/$(out answer)/$(posted)"
fresh; pr_json OPEN true CHANGES_REQUESTED acme site
rc=$(gate)
check "draft PR -> no answer"                    "0/false" "$rc/$(out answer)"

verdict() { # env assignments as args
  env PR=7 REPO=acme/site GH_TOKEN=x HEAD_SHA=abc123 RUN_URL=https://example/run TURNS=120 \
      REVIEW_RESULT=success "$@" bash "$ROOT/scripts/verdict-check.sh" > "$STUB_DIR/stdout" 2>&1
  echo $?
}
review() { printf '[{"user":{"login":"%s"},"commit_id":"%s","state":"%s"}]' "$1" "$2" "$3"; }

echo "verdict-check.sh"
fresh; review 'claude[bot]' abc123 APPROVED > "$STUB_DIR/reviews.json"
check "verdict on this commit -> green, silent"  "0/0" "$(verdict)/$(posted)"
fresh; review 'claude[bot]' abc123 CHANGES_REQUESTED > "$STUB_DIR/reviews.json"; echo 3 > "$STUB_DIR/pages"
check "verdict found across 3 pages -> green"    "0/0" "$(verdict)/$(posted)"
fresh; review 'claude' abc123 APPROVED > "$STUB_DIR/reviews.json"
check "verdict reported under the bare login 'claude' still counts -> green" "0/0" "$(verdict)/$(posted)"
fresh; review 'claude-impostor[bot]' abc123 APPROVED > "$STUB_DIR/reviews.json"
check "a different bot whose name merely starts with claude is NOT the reviewer -> RED" "1/1" "$(verdict)/$(posted)"
fresh; review 'claude[bot]' 0ldsha APPROVED > "$STUB_DIR/reviews.json"
check "stale approval from an earlier push -> RED + comment" "1/1" "$(verdict)/$(posted)"
fresh; review 'mark' abc123 APPROVED > "$STUB_DIR/reviews.json"
check "a human's approval is not the bot's verdict -> RED" "1/1" "$(verdict)/$(posted)"
fresh; review 'claude[bot]' abc123 COMMENTED > "$STUB_DIR/reviews.json"
check "inline-comment records (COMMENTED) are not a verdict -> RED" "1/1" "$(verdict)/$(posted)"
fresh
rc=$(verdict)
check "action skipped (job green) -> RED, 'declined to run'" "1/1" \
      "$rc/$(grep -c 'declined to run' "$STUB_DIR/posted.1")"
fresh
rc=$(verdict REVIEW_RESULT=failure)
check "review crashed -> RED, 'stopped before reaching a verdict', names the turn budget" "1/1/1" \
      "$rc/$(grep -c 'stopped before reaching a verdict' "$STUB_DIR/posted.1")/$(grep -c '120-turn' "$STUB_DIR/posted.1")"
fresh; touch "$STUB_DIR/api-fail"
check "API unreadable -> announces (safe direction), RED" "1/1" "$(verdict)/$(posted)"
fresh; printf '%s' '[{"body":"<!-- pr-reviewer:no-review:abc123 -->\nalready said"}]' > "$STUB_DIR/issue-comments.json"
check "re-run on the same commit -> RED, no second comment" "1/0" "$(verdict)/$(posted)"
fresh; printf '%s' '[{"body":"<!-- pr-reviewer:no-review:0ldsha -->\nolder commit"}]' > "$STUB_DIR/issue-comments.json"
check "announcement for an OLDER commit does not silence this one" "1/1" "$(verdict)/$(posted)"
fresh; verdict >/dev/null; first="$(head -c 4 "$STUB_DIR/posted.1")"
check "comment body starts at column 0 (indented = rendered as code)" "<!--" "$first"

echo "build.sh (npm, php and composer are stubs; nothing is installed or run for real)"
# bproj <file>=<content> ...   -> a fresh project folder with those files, stubs on PATH
bproj() {
  BP="$(mktemp -d)"; mkdir -p "$BP/bin"; : > "$BP/commands.txt"
  local kv f; for kv in "$@"; do f="${kv%%=*}"; mkdir -p "$BP/$(dirname "$f")"; printf '%s' "${kv#*=}" > "$BP/$f"; done
  # npm: `run lint` fails in a folder holding .lint-fail
  printf '%s\n' '#!/bin/sh' 'printf "%s %s\n" "$(pwd)" "$*" >> "$COMMAND_LOG"' \
    'if [ "$1 $2" = "run lint" ] && [ -f .lint-fail ]; then exit 1; fi' 'exit 0' > "$BP/bin/npm"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$BP/bin/composer"
  # php: -l fails on a file containing "invalid"; `artisan migrate` fails when MIGRATE_FAIL=1
  printf '%s\n' '#!/bin/sh' 'printf "%s %s\n" "$(pwd)" "$*" >> "$COMMAND_LOG"' \
    'if [ "$1" = "-r" ]; then printf "8.3.0"; exit 0; fi' \
    'if [ "$1" = "-l" ]; then grep -q invalid "$2" && exit 255; exit 0; fi' \
    'if [ "$2" = "migrate" ] && [ "${MIGRATE_FAIL:-0}" = 1 ]; then echo "SQLSTATE: no such table"; exit 1; fi' 'exit 0' > "$BP/bin/php"
  chmod +x "$BP/bin/"*
}
# brun <changed-files: a list, "-" for an empty list, "none" for no list at all> [env...]
brun() {
  local changed="$1"; shift
  case "$changed" in none) ;; -) : > "$BP/changed.txt" ;; *) printf '%s\n' $changed > "$BP/changed.txt" ;; esac
  (cd "$BP" && env -u BASE_SHA PATH="$BP/bin:$PATH" SKIP_MYSQL=1 STEP_TIMEOUT=5 COMMAND_LOG="$BP/commands.txt" \
     CHANGED_FILES_FILE="$BP/changed.txt" "$@" bash "$ROOT/scripts/build.sh" run >/dev/null 2>&1)
  echo $?
}
summary() { cat "$BP/.build-results/summary.txt"; }
overall() { grep -oE '^overall=[a-z]+' "$BP/.build-results/summary.txt" | cut -d= -f2; }
has()     { grep -qE "$1" "$BP/.build-results/summary.txt" && echo yes || echo no; }
ran()     { grep -cE "$1" "$BP/commands.txt" || true; }

pkg() { jq -cn --argjson s "${1:-{\}}" '{name:"fixture",private:true,scripts:$s}'; }
pkgws() { jq -cn --argjson s "${1:-{\}}" '{name:"fixture",private:true,workspaces:["apps/*"],scripts:$s}'; }
laravel=( 'composer.json={"require":{"php":"^8.3"}}' 'artisan=<?php' '.env=APP_KEY=base64:fixture'
          'phpunit.xml=<phpunit><php><env name="DB_CONNECTION" value="sqlite"/></php></phpunit>'
          'database/migrations/001_create.php=<?php' 'config/database.php=<?php' )

bproj "package.json=$(pkg '{"lint":"eslint .","build":"nuxt build"}')" '.lint-fail=x'
rc=$(brun "pages/index.vue")
check "node: a failing lint script turns the build red (D05)" "1/red/yes" "$rc/$(overall)/$(has 'reasons=.*lint failed')"
bproj "package.json=$(pkg '{"lint":"eslint .","build":"nuxt build"}')"
rc=$(brun "pages/index.vue")
check "node: lint and build pass -> green (D06)" "0/green" "$rc/$(overall)"

bproj "${laravel[@]}"
rc=$(brun "config/database.php" MIGRATE_FAIL=1)
check "laravel: config change breaks an unchanged migration -> red, never 'already failed before this PR' (D07)" \
      "1/red/yes/no" "$rc/$(overall)/$(has 'migrate_scope=unconfirmed')/$(has 'before this PR')"
bproj "${laravel[@]}"
rc=$(brun "database/migrations/001_create.php" MIGRATE_FAIL=1)
check "laravel: the PR's own migration fails -> red, attributed to the PR (D08)" "1/red/yes" "$rc/$(overall)/$(has 'migrate_scope=pr')"
bproj "${laravel[@]}"
rc=$(brun none MIGRATE_FAIL=1)
check "laravel: no file list and a migration fails -> red" "1/red" "$rc/$(overall)"
bproj "${laravel[@]}" 'app/Broken.php=<?php invalid'
rc=$(brun none)
check "laravel: no file list -> every PHP file is syntax-checked, and it says so" "1/red/yes" \
      "$rc/$(overall)/$(has '^changed_files=unavailable')"
bproj "${laravel[@]}" 'app/Broken.php=<?php invalid' 'vendor/pkg/Old.php=<?php invalid'
rc=$(brun "config/database.php")
check "laravel: with a file list, only the changed files are syntax-checked" "0/green/1" "$rc/$(overall)/$(ran ' -l ')"

bproj 'wp-config.php=<?php' 'wp-content/plugins/x/plugin.php=<?php invalid'
rc=$(brun none)
check "wordpress: no file list -> checks every PHP file instead of none (D09)" "1/red/yes/no" \
      "$rc/$(overall)/$(has '^changed_files=unavailable')/$(has 'files_checked=0')"
bproj 'wp-config.php=<?php' 'wp-content/plugins/x/plugin.php=<?php invalid'
rc=$(brun "-")
check "wordpress: an EMPTY list is a real empty diff -> nothing to check, green" "0/green/yes" "$rc/$(overall)/$(has 'files_checked=0')"
bproj 'wp-config.php=<?php' 'wp-content/plugins/x/plugin.php=<?php invalid'
rc=$(brun "wp-content/plugins/x/plugin.php")
check "wordpress: syntax error in a changed file -> red (D10)" "1/red" "$rc/$(overall)"

bproj "package.json=$(pkg '{"prepare":"husky"}')" "apps/web/package.json=$(pkg '{"lint":"eslint ."}')" 'apps/web/.lint-fail=x'
rc=$(brun "apps/web/page.js")
check "monorepo: a tooling-only root no longer hides a changed child app (D11)" "1/yes/yes" \
      "$rc/$(has '^project=apps/web toolchain=node .*lint=fail')/$(has 'apps/web: lint failed')"
bproj "package.json=$(pkgws '{"build":"turbo run build","lint":"turbo run lint"}')" "apps/web/package.json=$(pkg '{"build":"nuxt build"}')"
rc=$(brun "apps/web/page.js")
check "monorepo: a workspace root that builds its members -> members not built twice" "0/yes/0" \
      "$rc/$(has '^project=apps/web .*build=covered-by-root')/$(ran "apps/web run build")"
bproj "package.json=$(pkg '{}')" "apps/web/package.json=$(pkg '{"build":"x"}')" "apps/api/package.json=$(pkg '{"build":"x"}')"
rc=$(brun "apps/web/page.js")
check "monorepo: an untouched child is still skipped" "0/yes" "$rc/$(has '^project=apps/api .*reason=no-changed-files')"
bproj "package.json=$(pkg '{}')" "apps/web/package.json=$(pkg '{"build":"x"}')" "apps/api/package.json=$(pkg '{"build":"x"}')"
rc=$(brun "package-lock.json")
check "monorepo: a shared root lockfile change rebuilds every child" "0/no/1" \
      "$rc/$(has 'reason=no-changed-files')/$(ran "apps/api run build")"
bproj "package.json=$(pkg '{"build":"nuxt build"}')" "playground/package.json=$(pkg '{"build":"x"}')"
rc=$(brun "playground/app.vue")
check "an ordinary app root with its own build is unchanged: nested folders are not new projects" "0/no" \
      "$rc/$(has '^project=playground')"
bproj "package.json=$(pkgws '{"build":"turbo run build"}')" "apps/web/package.json=$(pkg '{"build":"x"}')" "docs/package.json=$(pkg '{"lint":"x"}')" 'docs/.lint-fail=x'
rc=$(brun "docs/index.md")
check "monorepo: a folder OUTSIDE the workspace globs is built on its own, not called covered" "1/no/yes" \
      "$rc/$(has '^project=docs .*covered-by-root')/$(has 'docs: lint failed')"
bproj "package.json=$(pkgws '{"test":"vitest"}')" "apps/web/package.json=$(pkg '{"lint":"x"}')" 'apps/web/.lint-fail=x'
rc=$(brun "apps/web/page.js")
check "monorepo: a root that only TESTS does not cover its members' lint and build" "1/no" \
      "$rc/$(has 'covered-by-root')"
bproj "package.json=$(pkg '{}')" "web/package.json=$(pkg '{"build":"x"}')" 'web/.nvmrc=18'
check "detect: a root that builds nothing does not pick the apps' Node version" "node_version=18" \
      "$(cd "$BP" && bash "$ROOT/scripts/build.sh" detect 2>/dev/null | grep '^node_version=')"
bproj 'package.json={"workspaces":["apps/*","!apps/legacy"],"scripts":{"build":"turbo run build"}}' \
      "apps/web/package.json=$(pkg '{"build":"x"}')" "apps/web/e2e/package.json=$(pkg '{"lint":"x"}')" 'apps/web/e2e/.lint-fail=x' \
      "apps/legacy/package.json=$(pkg '{"lint":"x"}')" 'apps/legacy/.lint-fail=x'
rc=$(brun "apps/web/e2e/a.js apps/legacy/a.js")
check "monorepo: 'apps/*' is ONE folder level, and '!apps/legacy' is not a member" "1/yes/no/no" \
      "$rc/$(has '^project=apps/web .*covered-by-root')/$(has '^project=apps/web/e2e .*covered-by-root')/$(has '^project=apps/legacy .*covered-by-root')"
bproj 'package.json={"workspaces":[".tools/*"],"scripts":{"build":"x"}}' "tools/x/package.json=$(pkg '{"lint":"x"}')" 'tools/x/.lint-fail=x'
rc=$(brun "tools/x/a.js")
check "monorepo: '.tools/*' is not 'tools/*'" "1/no" "$rc/$(has 'covered-by-root')"
bproj 'package.json={"scripts":{"build":"x"}}' 'pnpm-workspace.yaml=packages:
  - "apps/*"
onlyBuiltDependencies:
  - "lib/*"' "lib/x/package.json=$(pkg '{"lint":"x"}')" 'lib/x/.lint-fail=x'
rc=$(brun "lib/x/a.js")
check "monorepo: only the pnpm 'packages:' list names members" "1/no" "$rc/$(has 'covered-by-root')"

bproj 'package.json={"scripts":{"dev":"gulp"}}' '.nvmrc=16' 'wp-config.php=<?php' "wp-content/themes/t/package.json=$(pkg '{}')"
check "detect: a WordPress root keeps its own pinned Node version" "node_version=16" \
      "$(cd "$BP" && bash "$ROOT/scripts/build.sh" detect 2>/dev/null | grep '^node_version=')"
bproj "package.json=$(pkg '{}')" '.nvmrc=16' 'api/composer.json={}'
check "detect: a tooling root whose only child is PHP keeps its own Node version" "node_version=16" \
      "$(cd "$BP" && bash "$ROOT/scripts/build.sh" detect 2>/dev/null | grep '^node_version=')"

bproj "package.json=$(pkg '{"lint":"x","build":"x"}')" '.lint-fail=x'
rc=$(brun "a.js" RESULTS_DIR="$BP/abs-results")
check "an absolute RESULTS_DIR still works" "1/yes" "$rc/$(grep -q 'lint failed' "$BP/abs-results/summary.txt" && echo yes || echo no)"

bproj 'api/composer.json={}' 'api/app/Broken.php=<?php invalid' 'web/package.json={}'
rc=$(brun "api/app/Broken.php")
check "a Laravel app in a sub-folder syntax-checks ITS changed files (the list path was relative)" "1/red" "$rc/$(overall)"

echo "approval-guard.sh (review job)"
guard() { # env assignments as args
  env PR=7 REPO=acme/site GH_TOKEN=x EXPECT_SHA=abc123 SINCE=2026-09-23T10:00:00Z "$@" \
      bash "$ROOT/scripts/approval-guard.sh" > "$STUB_DIR/stdout" 2>&1
  echo $?
}
rv() { # login commit_id state submitted_at [id]
  jq -cn --argjson id "${5:-1}" --arg l "$1" --arg c "$2" --arg st "$3" --arg t "$4" \
    '{id:$id,user:{login:$l},commit_id:$c,state:$st,submitted_at:$t,body:"x"}'; }
dismissed() { grep -c 'dismissals' "$STUB_LOG" || true; }
fresh; echo "[$(rv 'claude[bot]' abc123 APPROVED 2026-09-23T10:05:00Z)]" > "$STUB_DIR/reviews.json"
check "approval of the commit this run reviewed -> left alone" "0/0/0" "$(guard)/$(dismissed)/$(posted)"
fresh; echo "[$(rv 'claude[bot]' newhead APPROVED 2026-09-23T10:05:00Z 42)]" > "$STUB_DIR/reviews.json"
rc=$(guard)
check "push during the review: approval landed on code nobody reviewed -> withdrawn + said" "0/1/1/1" \
      "$rc/$(dismissed)/$(grep -c 'reviews/42/dismissals' "$STUB_LOG")/$(posted)"
fresh; echo "[$(rv 'claude[bot]' 0ldsha APPROVED 2026-09-22T09:00:00Z)]" > "$STUB_DIR/reviews.json"
check "an OLD approval from an earlier run is not this run's business" "0/0" "$(guard)/$(dismissed)"
fresh; echo "[$(rv mark newhead APPROVED 2026-09-23T10:05:00Z)]" > "$STUB_DIR/reviews.json"
check "a human's approval is never touched" "0/0" "$(guard)/$(dismissed)"
fresh; echo "[$(rv 'claude[bot]' newhead CHANGES_REQUESTED 2026-09-23T10:05:00Z)]" > "$STUB_DIR/reviews.json"
check "a changes-requested verdict is never withdrawn" "0/0" "$(guard)/$(dismissed)"
fresh; echo "[$(rv 'claude[bot]' newhead APPROVED 2026-09-23T10:05:00Z)]" > "$STUB_DIR/reviews.json"; touch "$STUB_DIR/dismiss-fail"
rc=$(guard)
check "withdrawal refused by GitHub -> RED, and says so in the PR" "1/1" "$rc/$(posted)"
fresh; touch "$STUB_DIR/api-fail"
check "reviews unreadable -> RED (cannot prove no bad approval exists)" "1" "$(guard)"

echo "respond-withdraw.sh (the reply cannot approve; it can pull an approval)"
wd() { # env assignments as args
  env PR=7 REPO=acme/site GH_TOKEN=x GATE_HEAD=abc123 SINCE=2026-09-23T10:00:00Z "$@" \
      bash "$ROOT/scripts/respond-withdraw.sh" > "$STUB_DIR/stdout" 2>&1
  echo $?
}
ic() { # login created_at body
  jq -cn --arg l "$1" --arg t "$2" --arg b "$3" '{user:{login:$l},created_at:$t,body:$b,html_url:"https://example/c/1"}'; }
PULL='<!-- pr-reviewer:verdict=request-changes -->'
fresh; echo "[$(ic 'claude[bot]' 2026-09-23T10:05:00Z "🤖 **Automated reply.** missed a defect
$PULL")]" > "$STUB_DIR/issue-comments.json"
echo "[$(rv 'claude[bot]' abc123 APPROVED 2026-09-22T09:00:00Z 7),$(rv mark abc123 APPROVED 2026-09-22T09:00:00Z 8)]" > "$STUB_DIR/reviews.json"
rc=$(wd)
check "reply confirms a missed defect -> the bot's standing approval is pulled, a human's is not" "0/1/1/0" \
      "$rc/$(dismissed)/$(grep -c 'reviews/7/dismissals' "$STUB_LOG")/$(grep -c 'reviews/8/dismissals' "$STUB_LOG")"
fresh; echo "[$(ic 'claude[bot]' 2026-09-23T10:05:00Z "x
$PULL")]" > "$STUB_DIR/issue-comments.json"
echo "[$(rv 'claude[bot]' abc123 APPROVED 2026-09-22T09:00:00Z 7),$(rv 'claude[bot]' newhead APPROVED 2026-09-23T10:06:00Z 9)]" > "$STUB_DIR/reviews.json"
rc=$(wd)
check "a push that fixed it was approved meanwhile -> only the approval on the commit the reply read is pulled (round 4 #1)" \
      "0/1/0" "$rc/$(grep -c 'reviews/7/dismissals' "$STUB_LOG")/$(grep -c 'reviews/9/dismissals' "$STUB_LOG")"
fresh; echo "[$(ic 'claude[bot]' 2026-09-23T10:05:00Z "the marker is \`$PULL\` and it goes last
so this line is the last one")]" > "$STUB_DIR/issue-comments.json"
echo "[$(rv 'claude[bot]' abc123 APPROVED 2026-09-22T09:00:00Z)]" > "$STUB_DIR/reviews.json"
check "the marker quoted mid-comment pulls nothing: it must be the last line (round 4 #4)" "0/0" "$(wd)/$(dismissed)"
fresh; echo "[$(ic 'claude[bot]' 2026-09-23T10:05:00Z "x
$PULL")]" > "$STUB_DIR/issue-comments.json"
echo "[$(rv 'claude[bot]' 0ldsha APPROVED 2026-09-22T09:00:00Z 5)]" > "$STUB_DIR/reviews.json"
check "the standing approval is on an OLDER commit (docs-only push since) -> still pulled" "0/1" \
      "$(wd)/$(grep -c 'reviews/5/dismissals' "$STUB_LOG")"
fresh; echo "[$(ic 'claude[bot]' 2026-09-23T10:05:00Z "findings stand")]" > "$STUB_DIR/issue-comments.json"
echo "[$(rv 'claude[bot]' abc123 APPROVED 2026-09-22T09:00:00Z)]" > "$STUB_DIR/reviews.json"
check "no marker -> nothing pulled" "0/0" "$(wd)/$(dismissed)"
fresh; echo "[$(ic camile 2026-09-23T10:05:00Z "please
$PULL")]" > "$STUB_DIR/issue-comments.json"
echo "[$(rv 'claude[bot]' abc123 APPROVED 2026-09-22T09:00:00Z)]" > "$STUB_DIR/reviews.json"
check "the marker in a PERSON's comment is ignored" "0/0" "$(wd)/$(dismissed)"
fresh; echo "[$(ic 'claude[bot]' 2026-09-22T09:00:00Z "old
$PULL")]" > "$STUB_DIR/issue-comments.json"
echo "[$(rv 'claude[bot]' abc123 APPROVED 2026-09-22T09:00:00Z)]" > "$STUB_DIR/reviews.json"
check "a marker from an earlier reply is ignored" "0/0" "$(wd)/$(dismissed)"
fresh; echo "[$(ic 'claude[bot]' 2026-09-23T10:05:00Z "x
$PULL")]" > "$STUB_DIR/issue-comments.json"
echo "[$(rv 'claude[bot]' abc123 APPROVED 2026-09-22T09:00:00Z)]" > "$STUB_DIR/reviews.json"; touch "$STUB_DIR/dismiss-fail"
check "GitHub refuses -> RED (the approval still stands)" "1" "$(wd)"
fresh; touch "$STUB_DIR/api-fail"
check "comments unreadable -> RED" "1" "$(wd)"
fresh; echo "[$(ic 'claude[bot]' 2026-09-23T10:05:00Z "   ")]" > "$STUB_DIR/issue-comments.json"
check "a blank bot comment does not break the check (round 5 #3)" "0/0" "$(wd)/$(dismissed)"

echo "check-caller-contract.py (each mutation must be caught)"
contract() { # perl substitution for review.yml, perl substitution for the template ('' = leave alone)
  local d; d="$(mktemp -d)"; mkdir -p "$d/tests"
  perl -0pe "${1:-s/^\$//m}" "$ROOT/.github/workflows/review.yml" > "$d/review.yml"
  perl -0pe "${2:-s/^\$//m}" "$ROOT/caller-template.yml" > "$d/caller.yml"
  cp "$ROOT/tests/gates.golden" "$d/tests/"
  python3 "$ROOT/scripts/check-caller-contract.py" "$d/review.yml" "$d/caller.yml" "$d/tests/gates.golden" >"$d/out" 2>&1
  echo $?
}
# first occurrence only, except where a case says it needs every occurrence (/g)
check "unmodified files pass"                     0 "$(contract '' '')"
check "respond asks for issues: write (the 16 Sep outage) -> caught" 1 "$(contract 's/^      issues: read$/      issues: write/m' '')"
check "bot filter removed from ONE respond clause -> caught" 1 "$(contract "s/github\\.event\\.comment\\.user\\.type != 'Bot' &&//" '')"
check "fork test removed from the build gate -> caught" 1 "$(contract 's/github\.event\.pull_request\.head\.repo\.full_name == github\.repository &&//' '')"
check "a gate reworded (draft == false -> !draft) -> caught by the golden copy" 1 "$(contract 's/github\.event\.pull_request\.draft == false/!github.event.pull_request.draft/' '')"
check "concurrency group renamed to the old callers' name -> caught" 1 "$(contract 's/^    prr-\$/    pr-review-\$/m' '')"
check "REVIEWER_REF pointed at main -> caught"    1 "$(contract 's/^  REVIEWER_REF: v1$/  REVIEWER_REF: main/m' '')"
check "template pinned to @main -> caught"        1 "$(contract '' 's/review\.yml\@v2$/review.yml\@main/m')"
check "an if: put back in the template -> caught" 1 "$(contract '' 's/^  pr-review:$/  pr-review:\n    if: github.actor != 0/m')"
check "template grants less than the field (issues: none) -> caught" 1 "$(contract '' 's/^      issues: read$/      issues: none/m')"
check "permissions: write-all on a job (invisible to the checker until 21 Sep) -> caught" 1 "$(contract 's/^    permissions:\n      # MUST stay within.*?id-token: write\n/    permissions: write-all\n/ms' '')"
check "a job's permissions block deleted -> caught" 1 "$(contract 's/^    permissions:\n      contents: read\n(?:      #[^\n]*\n)*      pull-requests: read\n    outputs:/    outputs:/m' '')"
golden_too() { # widen a gate AND regenerate the golden, as an author told "regenerate it" would
  local d; d="$(mktemp -d)"; mkdir -p "$d/tests"
  perl -0pe "$1" "$ROOT/.github/workflows/review.yml" > "$d/review.yml"
  python3 "$ROOT/scripts/check-caller-contract.py" --print-gates "$d/review.yml" > "$d/tests/gates.golden"
  python3 "$ROOT/scripts/check-caller-contract.py" "$d/review.yml" "$ROOT/caller-template.yml" "$d/tests/gates.golden" >"$d/out" 2>&1
  echo $?
}
check "respond widened with an extra || clause, golden regenerated -> STILL caught" 1 "$(golden_too "s/        \\)\\n      \\}\\}\\n    # One answer/        ) || github.event_name == 'issue_comment'\\n      }}\\n    # One answer/")"
check "bot filter neutered with '|| true', golden regenerated -> STILL caught" 1 "$(golden_too "s/github\\.event\\.comment\\.user\\.type != 'Bot' &&/(github.event.comment.user.type != 'Bot' || true) \&\&/g")"
check "permissions: {} on the review job (can no longer post a verdict) -> caught" 1 "$(contract 's/^    timeout-minutes: 25\n    permissions:\n      contents: read\n      pull-requests: write\n      issues: read\n      id-token: write\n/    timeout-minutes: 25\n    permissions: {}\n/m' '')"
check "workflow-level permissions: write-all in review.yml -> caught" 1 "$(contract 's/^env:\n/permissions: write-all\n\nenv:\n/m' '')"
check "unlisted clause dropped (!inputs.skip_build), golden regenerated -> STILL caught" 1 "$(golden_too 's/ &&\n        !inputs\.skip_build//')"
check "respond stops skipping DRAFT PRs, golden regenerated -> STILL caught" 1 "$(golden_too "s/(github\\.event_name == 'pull_request_review_comment' &&\\n)          github\\.event\\.pull_request\\.draft == false &&\\n/\$1/")"
check "a job with no gate at all -> caught"       1 "$(contract 's/^    name: build\n    if: >-\n/    name: build\n    env:\n      X: >-\n/m' '')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
