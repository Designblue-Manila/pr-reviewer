#!/usr/bin/env bash
# build.sh — deterministic "does this PR build and do its tests pass?" check.
#
# Runs inside the PR checkout. No AI, no network beyond package registries.
#
#   build.sh detect   -> prints key=value lines for the workflow (node/php versions, flags)
#   build.sh run      -> installs, builds, migrates, tests every project it finds;
#                        writes .build-results/summary.txt + per-project logs;
#                        exits 1 when something is red (build/boot/migrate/tests)
#
# Environment (all optional):
#   BASE_SHA        base commit of the PR; enables "changed files" scoping and php -l
#   RESULTS_DIR     default .build-results
#   STEP_TIMEOUT    seconds per install/build/test step, default 900
#   NODE_DEFAULT    Node major used when a project states none, default 22
#   PHP_DEFAULT     PHP version used when composer.json states none, default 8.3
#   MYSQL_HOST/PORT/USER/PASSWORD  CI database (default 127.0.0.1/3306/root/root)
#   SKIP_MYSQL=1    never touch MySQL (local dry runs)
set -u
set -o pipefail

RESULTS_DIR="${RESULTS_DIR:-.build-results}"
STEP_TIMEOUT="${STEP_TIMEOUT:-900}"
NODE_DEFAULT="${NODE_DEFAULT:-22}"
PHP_DEFAULT="${PHP_DEFAULT:-8.3}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD-root}"
ROOT="$(pwd)"
export MYSQL_PWD="$MYSQL_PASSWORD"

# ---------------------------------------------------------------- helpers ---

log() { printf '%s\n' "$*" >&2; }

# portable timeout (macOS lacks GNU timeout; coreutils installs gtimeout)
run_timed() {
  if command -v timeout >/dev/null 2>&1; then timeout "$STEP_TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$STEP_TIMEOUT" "$@"
  else "$@"; fi
}

# json_get <file> <dotted.path>  -> value or empty (uses node when present, else python3)
json_get() {
  local file="$1" path="$2"
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs=require("fs"); let o;
      try { o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch { process.exit(0); }
      for (const k of process.argv[2].split(".")) { if (o==null) break; o=o[k]; }
      if (o==null) process.exit(0);
      process.stdout.write(typeof o==="object" ? JSON.stringify(o) : String(o));
    ' "$file" "$path" 2>/dev/null
  else
    python3 - "$file" "$path" <<'PY' 2>/dev/null
import json,sys
try: o=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for k in sys.argv[2].split("."):
    if o is None: break
    o=o.get(k) if isinstance(o,dict) else None
if o is None: sys.exit(0)
print(o if not isinstance(o,(dict,list)) else json.dumps(o), end="")
PY
  fi
}

# first "major" or "major.minor" number in a semver range string
first_version() { printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1; }

# highest PHP minimum any locked package requires ("^7.4 || ^8.0" counts as 7.4); prints "8.4" or nothing
# (kept as a variable, not a heredoc inside $(...), because bash 3.2 mis-parses that)
read -r -d '' PHP_LOCK_MIN_PY <<'PY' || true
import json,re,sys
try: lock=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
best=(0,0)
for p in lock.get("packages",[]):
    c=(p.get("require") or {}).get("php","")
    mins=[(int(m.group(1)),int(m.group(2))) for m in re.finditer(r'(\d+)\.(\d+)', c)]
    if mins and min(mins)>best: best=min(mins)
if best[0]: print("%d.%d"%best)
PY

# --------------------------------------------------------- project discovery ---

# Emits "<dir>\t<kind>" lines. kind = php | node | wp | node-covered
# Root wins; otherwise every dir up to 3 deep holding composer.json or package.json.
# A dir with composer.json is php (its package.json is Vite assets, not a second project).
#
# A root package.json wins outright only when it is an app that builds itself. A root that
# declares workspaces, or builds and tests nothing (husky, prettier), sits ABOVE the apps:
# returning it alone left a changed child app unbuilt while the check said green. Its
# nested projects are listed too — as `node-covered` when the root has a workspace
# build/test that runs them (so they are not built twice), as projects of their own when not.
discover() {
  if [ -f composer.json ]; then echo -e ".\tphp"; return; fi
  if [ -f package.json ]; then
    echo -e ".\tnode"
    local ws=false scripts=false
    { [ -n "$(json_get package.json workspaces)" ] || [ -f pnpm-workspace.yaml ]; } && ws=true
    { [ -n "$(json_get package.json scripts.build)" ] || [ -n "$(json_get package.json scripts.test)" ]; } && scripts=true
    [ "$ws" = false ] && [ "$scripts" = true ] && return
    # WordPress with a CSS-tooling package.json: its plugins' composer.json files are not
    # projects of ours. Unchanged from before (still built as node only — a known gap).
    { [ -d wp-content ] || ls wp-config*.php >/dev/null 2>&1; } && return
    local builds=false dir kind globs
    [ -n "$(json_get package.json scripts.build)" ] && builds=true
    globs="$(workspace_globs)"
    nested | while IFS=$'\t' read -r dir kind; do
      [ "$kind" = node ] && [ "$builds" = true ] && is_member "$dir" "$globs" && kind=node-covered
      printf '%s\t%s\n' "$dir" "$kind"
    done
    return
  fi
  if [ -d wp-content ] || ls wp-config*.php >/dev/null 2>&1; then echo -e ".\twp"; return; fi
  nested
}

# The root's workspace members, from package.json (array or {packages: [...]}) or
# pnpm-workspace.yaml, as one anchored regex per line: "+re" includes, "-re" excludes
# (a "!apps/legacy" glob). `*` is ONE folder level, `**` any depth — as npm, yarn and pnpm
# read them. Only a member is built by the root's own build script.
# (kept as a variable, like PHP_LOCK_MIN_PY, because bash 3.2 mis-parses a heredoc in $(...))
read -r -d '' WORKSPACE_GLOBS_PY <<'PY' || true
import json,re
def out(g):
    g=g.strip().rstrip("/"); neg=g.startswith("!"); g=g[1:] if neg else g
    while g.startswith("./"): g=g[2:]
    if not g or g.startswith("../"): return
    r=""; i=0
    while i<len(g):
        if g.startswith("**/",i): r+="(.*/)?"; i+=3
        elif g.startswith("**",i): r+=".*"; i+=2
        elif g[i]=="*": r+="[^/]*"; i+=1
        elif g[i]=="?": r+="[^/]"; i+=1
        else: r+=re.escape(g[i]); i+=1
    print(("-" if neg else "+")+"^"+r+"$")
try:
    w=json.load(open("package.json")).get("workspaces") or []
    if isinstance(w,dict): w=w.get("packages") or []
    for g in w: out(g)
except Exception: pass
try:
    inside=False
    for line in open("pnpm-workspace.yaml"):
        if re.match(r"\S", line): inside=line.startswith("packages:")
        m=re.match(r"\s+-\s*['\"]?([^'\"#\s]+)", line)
        if inside and m: out(m.group(1))
except Exception: pass
PY
workspace_globs() { python3 -c "$WORKSPACE_GLOBS_PY" 2>/dev/null; }
is_member() {  # dir, the lines workspace_globs printed -> member when an include matches and no exclude does
  local dir="$1" line hit=1 re
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    re="${line#?}"
    [[ "$dir" =~ $re ]] || continue
    case "$line" in -*) return 1 ;; +*) hit=0 ;; esac
  done <<< "$2"
  return $hit
}

# (no -mindepth: under it find never tests, so never prunes, a top-level node_modules)
nested() {
  find . -maxdepth 4 \
       \( -name node_modules -o -name vendor -o -name .git -o -name dist -o -name .output -o -name .nuxt -o -name storage -o -name public \) -prune -o \
       \( -name composer.json -o -name package.json \) -print 2>/dev/null \
    | sed 's#^\./##' | grep / | sort \
    | awk -F/ '{ dir=$0; sub(/\/[^\/]*$/,"",dir); file=$NF;
                 if (file=="composer.json") { kind[dir]="php" }
                 else if (!(dir in kind)) { kind[dir]="node" } }
               END { for (d in kind) print d "\t" kind[d] }' \
    | sort
}

# ------------------------------------------------------------ detect mode ---

detect_node_version() {
  local dir="$1" v=""
  [ -f "$dir/.nvmrc" ] && v="$(tr -d 'v \n\r' < "$dir/.nvmrc")"
  [ -z "$v" ] && [ -f "$dir/.node-version" ] && v="$(tr -d 'v \n\r' < "$dir/.node-version")"
  [ -z "$v" ] && v="$(first_version "$(json_get "$dir/package.json" engines.node)")"
  [ -z "$v" ] && v="$NODE_DEFAULT"
  printf '%s' "$v"
}

detect_php_version() {
  local dir="$1" v lockmin
  v="$(first_version "$(json_get "$dir/composer.json" require.php)")"
  case "$v" in ''|8) v="$PHP_DEFAULT" ;; esac
  # composer.json can allow an older PHP than the locked packages actually need
  # (e.g. "^8.3" with symfony/clock requiring >=8.4.1); take the highest lock-file minimum
  if [ -f "$dir/composer.lock" ]; then
    lockmin="$(python3 -c "$PHP_LOCK_MIN_PY" "$dir/composer.lock" 2>/dev/null)"
    if [ -n "$lockmin" ]; then
      # only move forward within the same major the project declares
      if [ "${lockmin%%.*}" = "${v%%.*}" ] && [ "$(printf '%s\n%s\n' "$v" "$lockmin" | sort -V | tail -1)" = "$lockmin" ]; then v="$lockmin"; fi
    fi
  fi
  printf '%s' "$v"
}

detect_pm() {
  local dir="$1" pm
  pm="$(json_get "$dir/package.json" packageManager | cut -d@ -f1)"
  if [ -z "$pm" ]; then
    if [ -f "$dir/pnpm-lock.yaml" ]; then pm=pnpm
    elif [ -f "$dir/yarn.lock" ]; then pm=yarn
    else pm=npm; fi
  fi
  printf '%s' "$pm"
}

cmd_detect() {
  local has_node=false has_php=false node_version="" php_version="" projects="" found
  found="$(discover)"
  while IFS=$'\t' read -r dir kind; do
    [ -z "$dir" ] && continue
    [ "$kind" = node-covered ] && continue
    projects="${projects}${dir}:${kind} "
    case "$kind" in
      node) has_node=true
            # a tooling-only root (husky, prettier) above real Node apps is not the one whose
            # Node matters; with no other Node app listed (WordPress, a PHP child) it is
            if [ -z "$node_version" ] && ! { [ "$dir" = . ] && [ -z "$(json_get package.json scripts.build)" ] \
                 && [ -z "$(json_get package.json scripts.test)" ] \
                 && printf '%s\n' "$found" | grep -qE $'^[^.][^\t]*\tnode$'; }; then
              node_version="$(detect_node_version "$dir")"
            fi ;;
      php)  has_php=true;  [ -z "$php_version" ]  && php_version="$(detect_php_version "$dir")"
            # Laravel repos ship a package.json too; only set up Node if it is really used in CI
            ;;
      wp)   has_php=true;  [ -z "$php_version" ]  && php_version="$PHP_DEFAULT" ;;
    esac
  done <<< "$found"
  echo "has_node=$has_node"
  echo "has_php=$has_php"
  echo "node_version=${node_version:-$NODE_DEFAULT}"
  echo "php_version=${php_version:-$PHP_DEFAULT}"
  echo "projects=${projects% }"
}

# --------------------------------------------------------------- run mode ---

CHANGED_FILE=""
CHANGED_STATUS=unavailable   # ok = the PR's file list is known (an empty list is a real empty diff)
SUMMARY=""
RED_REASONS=""

changed_files_for() {  # dir -> prints changed paths under dir (relative to repo root)
  local dir="$1"
  [ -z "$CHANGED_FILE" ] && return 0
  if [ "$dir" = "." ]; then cat "$CHANGED_FILE"; else grep -E "^${dir}/" "$CHANGED_FILE" || true; fi
}

# PHP files to syntax-check in the current folder: the PR's changed ones, or — when the
# file list could not be read — every tracked PHP file outside vendor/node_modules.
# Checking none and calling it `lint=ok` is how WordPress PRs went green unread.
php_files_to_lint() {  # dir (as the repo root sees it)
  local dir="$1"
  if [ "$CHANGED_STATUS" = ok ]; then
    changed_files_for "$dir" | grep -E '\.php$' | while IFS= read -r f; do printf '%s\n' "${f#"$dir"/}"; done
  elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -- '*.php' | grep -vE '(^|/)(vendor|node_modules)/' || true
  else
    find . \( -name vendor -o -name node_modules -o -name .git \) -prune -o -name '*.php' -print | sed 's#^\./##'
  fi
}

slug() { printf '%s' "$1" | sed 's#^\.$#root#; s#[/ ]#-#g'; }

mysql_ready=""
ensure_mysql() {
  [ -n "$mysql_ready" ] && return 0
  [ "${SKIP_MYSQL:-0}" = "1" ] && { mysql_ready=skipped; return 1; }
  if command -v mysql >/dev/null 2>&1 && mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -e 'select 1' >/dev/null 2>&1; then
    mysql_ready=yes; return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "starting mysql:8.4 in docker"
    docker run -d --name pr-review-mysql -p "${MYSQL_PORT}:3306" \
      -e MYSQL_ROOT_PASSWORD="$MYSQL_PASSWORD" mysql:8.4 >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      if docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" pr-review-mysql mysqladmin ping -uroot --silent >/dev/null 2>&1 \
         && mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -e 'select 1' >/dev/null 2>&1; then
        mysql_ready=yes; return 0
      fi
      sleep 2
    done
  fi
  mysql_ready=unavailable; return 1
}

mysql_exec() { mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -e "$1" >/dev/null 2>&1; }

# Failures that mean "the runner could not provide something", not "the code is wrong".
# They downgrade a suite that produced NO result at all; they never mask a suite that ran.
PHP_ENV_ERRORS='SQLSTATE\[HY000\] \[2002\]|could not find driver|Connection refused|Access denied for user|Unknown database|Unable to read key from file|No application encryption key'

# active (uncommented) <env name="X" value="Y"/> from phpunit.xml
phpunit_env() { [ -f phpunit.xml ] && grep -v '<!--' phpunit.xml | grep -oE "name=\"$1\" value=\"[^\"]*\"" | sed 's/.*value="//; s/"$//' | head -1; }

set_env_kv() {  # file key value  (adds the line when missing)
  local f="$1" k="$2" v="$3"
  if grep -qE "^${k}=" "$f"; then sed -i.bak -E "s|^${k}=.*|${k}=${v}|" "$f" && rm -f "$f.bak"; else printf '%s=%s\n' "$k" "$v" >> "$f"; fi
}

record() { SUMMARY="${SUMMARY}$1"$'\n'; log "  $1"; }
status_of() { grep -E "^$2=" "$1/status.txt" 2>/dev/null | head -1 | cut -d= -f2-; }
red() { RED_REASONS="${RED_REASONS}$1; "; }

build_node() {
  local dir="$1" out="$2" pm nodev line install lint build tests
  pm="$(detect_pm "$dir")"; nodev="$(node --version 2>/dev/null || echo none)"
  ( cd "$dir" || exit 1

    # package manager — installed with npm, not corepack: the corepack bundled with older
    # Node releases carries stale registry signing keys and fails with "Cannot find matching keyid".
    pm_spec="$(json_get package.json packageManager)"          # e.g. pnpm@9.12.2+sha512…
    pm_ver="$(printf '%s' "$pm_spec" | sed -E 's/^[^@]*@//; s/\+.*$//')"
    case "$pm" in
      pnpm)
        if [ -z "$pm_ver" ]; then
          # match the lockfile generation so install behaviour is the one the repo expects
          case "$(grep -m1 -oE "lockfileVersion: '?[0-9]+" pnpm-lock.yaml 2>/dev/null | grep -oE '[0-9]+$')" in
            9) pm_ver=9 ;; 6) pm_ver=8 ;; 5) pm_ver=7 ;; *) pm_ver=latest ;;
          esac
        fi
        npm i -g "pnpm@$pm_ver" >"$out/pm-install.log" 2>&1 || npm i -g pnpm >>"$out/pm-install.log" 2>&1
        # pnpm 10+ refuses dependency build scripts (esbuild, sharp…) unless allowed; CI needs them
        export npm_config_dangerously_allow_all_builds=true npm_config_strict_dep_builds=false CI=true ;;
      yarn)
        if [ -n "$pm_ver" ] && command -v corepack >/dev/null 2>&1; then
          npm i -g corepack@latest >"$out/pm-install.log" 2>&1; corepack enable >>"$out/pm-install.log" 2>&1 || true
        fi
        command -v yarn >/dev/null 2>&1 || npm i -g yarn >>"$out/pm-install.log" 2>&1 ;;
    esac

    [ -f .env ] || { [ -f .env.example ] && cp .env.example .env; }

    # install (frozen first; an out-of-sync lockfile is noted, not fatal)
    install=ok
    case "$pm" in
      pnpm) run_timed pnpm install --frozen-lockfile >"$out/install.log" 2>&1 \
            || { echo "lockfile=out-of-sync" > "$out/notes.txt"; run_timed pnpm install --no-frozen-lockfile >>"$out/install.log" 2>&1 || install=fail; } ;;
      yarn) run_timed yarn install --frozen-lockfile >"$out/install.log" 2>&1 \
            || { echo "lockfile=out-of-sync" > "$out/notes.txt"; run_timed yarn install >>"$out/install.log" 2>&1 || install=fail; } ;;
      *)    if [ -f package-lock.json ]; then
              run_timed npm ci >"$out/install.log" 2>&1 \
              || { echo "lockfile=out-of-sync" > "$out/notes.txt"; run_timed npm install >>"$out/install.log" 2>&1 || install=fail; }
            else
              echo "lockfile=missing" > "$out/notes.txt"; run_timed npm install >"$out/install.log" 2>&1 || install=fail
            fi ;;
    esac
    echo "install=$install" > "$out/status.txt"
    [ "$install" = fail ] && exit 0

    has_script() { [ -n "$(json_get package.json "scripts.$1")" ]; }
    runs() { case "$pm" in pnpm) run_timed pnpm run "$1" ;; yarn) run_timed yarn run "$1" ;; *) run_timed npm run "$1" ;; esac; }

    lint=none; if has_script lint; then runs lint >"$out/lint.log" 2>&1 && lint=ok || lint=fail; fi
    build=none; if has_script build; then runs build >"$out/build.log" 2>&1 && build=ok || build=fail; fi
    tests=none
    if has_script test && ! json_get package.json scripts.test | grep -q 'no test specified'; then
      runs test >"$out/test.log" 2>&1 && tests=passed || tests=failed
    fi
    echo "lint=$lint" >> "$out/status.txt"; echo "build=$build" >> "$out/status.txt"; echo "tests=$tests" >> "$out/status.txt"
  )
  install="$(status_of "$out" install)"; lint="$(status_of "$out" lint)"; build="$(status_of "$out" build)"; tests="$(status_of "$out" tests)"
  line="project=$dir toolchain=node pm=$pm node=$nodev install=${install:-fail} lint=${lint:-none} build=${build:-none} tests=${tests:-none}"
  [ -f "$out/notes.txt" ] && line="$line $(tr '\n' ' ' < "$out/notes.txt" | sed 's/ $//')"
  record "$line"
  [ "${install:-fail}" = fail ] && red "$dir: install failed"
  # the repo's own lint script, not a rule of ours: PHP syntax errors were already red
  [ "${lint:-none}" = fail ] && red "$dir: lint failed"
  [ "${build:-none}" = fail ] && red "$dir: build failed"
  [ "${tests:-none}" = failed ] && red "$dir: tests failed"
  return 0
}

build_php() {
  local dir="$1" out="$2" phpv line install boot migrate tests db lint dbname env_errors
  phpv="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo none)"
  ( cd "$dir" || exit 1
    install=ok boot=none migrate=none tests=none db=none lint=ok

    # php -l on the changed PHP files (syntax errors before anything else)
    for rel in $(php_files_to_lint "$dir"); do
      [ -f "$rel" ] || continue
      php -l "$rel" >>"$out/lint.log" 2>&1 || lint=fail
    done

    [ -f .env ] || { [ -f .env.example ] && cp .env.example .env; }
    [ -f .env.testing ] || { [ -f .env.testing.example ] && cp .env.testing.example .env.testing; }

    # database: the repo's phpunit.xml decides (sqlite in memory, or MySQL)
    if [ "$(phpunit_env DB_CONNECTION)" = sqlite ]; then
      db=sqlite
    else
      if ensure_mysql; then
        db=mysql
        for f in .env .env.testing; do
          [ -f "$f" ] || continue
          set_env_kv "$f" DB_CONNECTION mysql
          set_env_kv "$f" DB_HOST "$MYSQL_HOST"
          set_env_kv "$f" DB_PORT "$MYSQL_PORT"
          set_env_kv "$f" DB_USERNAME "$MYSQL_USER"
          set_env_kv "$f" DB_PASSWORD "$MYSQL_PASSWORD"
          set_env_kv "$f" DB_DATABASE "$(grep -E '^DB_DATABASE=' "$f" | cut -d= -f2- | tr -d '"'"'"' ' | grep . || echo ci_test)"
        done
        # create every database name the repo can end up using
        for dbname in "$(phpunit_env DB_DATABASE)" \
                      "$(grep -E '^DB_DATABASE=' .env 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')" \
                      "$(grep -E '^DB_DATABASE=' .env.testing 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')"; do
          [ -n "$dbname" ] && [ "$dbname" != ":memory:" ] && mysql_exec "CREATE DATABASE IF NOT EXISTS \`$dbname\`;"
        done
        # phpunit.xml may force its own credentials; honour them
        u="$(phpunit_env DB_USERNAME)"; p="$(phpunit_env DB_PASSWORD)"
        if [ -n "$u" ] && [ "$u" != "$MYSQL_USER" ]; then
          mysql_exec "CREATE USER IF NOT EXISTS '$u'@'%' IDENTIFIED BY '$p'; GRANT ALL ON *.* TO '$u'@'%'; FLUSH PRIVILEGES;"
        fi
      else
        db=unavailable
      fi
    fi

    run_timed composer install --no-interaction --prefer-dist --no-progress >"$out/install.log" 2>&1 || install=fail
    # a composer.json whose php pin is older than what its own lockfile needs: retry ignoring the php platform check
    if [ "$install" = fail ] && grep -q "your php version .* does not satisfy" "$out/install.log"; then
      echo "php-platform=ignored" >> "$out/notes.txt"
      run_timed composer install --no-interaction --prefer-dist --no-progress --ignore-platform-req=php >>"$out/install.log" 2>&1 && install=ok
    fi
    if [ "$install" = ok ]; then
      # `APP_KEY=` followed by spaces and a trailing `# comment` is an EMPTY key, but
      # `.+` matches that whitespace and the check passes — which is how parola-api ran
      # its whole suite with no app key. Require a real, non-comment first character.
      has_app_key() { grep -qE '^APP_KEY=[[:space:]]*[^[:space:]#]' "$1" 2>/dev/null; }
      has_app_key .env || php artisan key:generate --force >>"$out/install.log" 2>&1 || true
      [ -f .env.testing ] && ! has_app_key .env.testing &&
        set_env_kv .env.testing APP_KEY "$(grep -E '^APP_KEY=' .env | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]')"
      # Passport needs its RSA key pair on disk; a fresh checkout has none
      if grep -q '"laravel/passport"' composer.json && [ -f artisan ]; then
        php artisan passport:keys --force >>"$out/install.log" 2>&1 || true
      fi

      # boot check: the app must construct, register providers and load routes
      if [ -f artisan ]; then
        run_timed php artisan about >"$out/boot.log" 2>&1 && boot=ok || boot=fail
        # migrations on a fresh database — the first thing a bad migration breaks
        if [ "$boot" = ok ] && [ -d database/migrations ] && [ "$db" != unavailable ]; then
          if [ "$db" = sqlite ]; then
            DB_CONNECTION=sqlite DB_DATABASE=:memory: run_timed php artisan migrate --force --no-interaction >"$out/migrate.log" 2>&1 && migrate=ok || migrate=fail
          else
            run_timed php artisan migrate --force --no-interaction >"$out/migrate.log" 2>&1 && migrate=ok || migrate=fail
          fi
        fi
      fi

      # tests
      if ls tests/**/*Test.php tests/*Test.php >/dev/null 2>&1 || find tests -name '*Test.php' 2>/dev/null | grep -q .; then
        if [ -f artisan ]; then run_timed php artisan test --no-ansi >"$out/test.log" 2>&1 && tests=passed || tests=failed
        elif [ -x vendor/bin/phpunit ]; then run_timed vendor/bin/phpunit >"$out/test.log" 2>&1 && tests=passed || tests=failed
        fi
        # A "Tests:" summary line means the suite RAN. That decides the verdict —
        # never an error pattern found somewhere in the log. One environment-flavoured
        # failure (a missing APP_KEY in an unrelated test, say) used to reclassify the
        # whole run as `unrunnable`, which the reviewer is told to treat as a Nit — so a
        # run with real failures alongside it was reported green and could be approved.
        tl="$(sed -E 's/\x1b\[[0-9;]*m//g' "$out/test.log" | grep -E '^\s*Tests:' | tail -1)"
        if [ -z "$tl" ]; then
          # no summary at all: the suite never got far enough to run a single test
          if [ "$tests" = failed ] && grep -qiE "$PHP_ENV_ERRORS" "$out/test.log"; then
            tests=unrunnable
          fi
        else
          np="$(printf '%s' "$tl" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')"
          nf="$(printf '%s' "$tl" | grep -oE '[0-9]+ (failed|errors?)' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)"
          [ "$tests" = passed ] && tests="passed:${np:-0}"
          [ "$tests" = failed ] && tests="failed:${nf:-?}/${np:-0}"
          # the reviewer still needs to know some of those failures look environmental,
          # so it can name which — but the run stays failed, and stays red.
          if [ "$tests" != "${tests#failed}" ]; then
            env_errors="$(grep -ciE "$PHP_ENV_ERRORS" "$out/test.log" || true)"
          fi
        fi
      fi
    fi
    { echo "install=$install"; echo "boot=$boot"; echo "migrate=$migrate"; echo "tests=$tests"; echo "db=$db"; echo "lint=$lint"; echo "env_errors=${env_errors:-0}"; } > "$out/status.txt"
  )
  install="$(status_of "$out" install)"; lint="$(status_of "$out" lint)"; boot="$(status_of "$out" boot)"
  migrate="$(status_of "$out" migrate)"; tests="$(status_of "$out" tests)"; db="$(status_of "$out" db)"
  env_errors="$(status_of "$out" env_errors)"
  # A failed migration is ALWAYS red. `migrate_scope=pr` = the PR changed a migration;
  # `unconfirmed` = it did not, but nobody has run the base branch to prove the failure is
  # older: a config, provider, model or dependency change breaks an untouched migration
  # just as well. This used to print "already fail before this PR" on no evidence.
  mscope=""
  if [ "${migrate:-none}" = fail ]; then
    mscope=unconfirmed
    [ "$CHANGED_STATUS" = ok ] && changed_files_for "$dir" | grep -q "database/migrations/" && mscope=pr
  fi
  line="project=$dir toolchain=php php=$phpv install=${install:-fail} lint=${lint:-ok} boot=${boot:-none} migrate=${migrate:-none} tests=${tests:-none} db=${db:-none}"
  [ -n "$mscope" ] && line="$line migrate_scope=$mscope"
  # the count is a hint for the reviewer, not a downgrade: the run is still failed and still red
  [ "${env_errors:-0}" != 0 ] && line="$line env_errors=$env_errors"
  record "$line"
  [ "${install:-fail}" = fail ] && red "$dir: composer install failed"
  [ "${lint:-ok}" = fail ] && red "$dir: PHP syntax error"
  [ "${boot:-none}" = fail ] && red "$dir: application failed to boot"
  [ -n "$mscope" ] && red "$dir: migrations failed on a fresh database"
  case "${tests:-none}" in failed*) red "$dir: tests failed" ;; esac
  return 0
}

build_wp() {
  local dir="$1" out="$2" lint=ok n=0 rel
  for rel in $(php_files_to_lint "$dir"); do
    [ -f "$rel" ] || continue
    n=$((n+1)); php -l "$rel" >>"$out/lint.log" 2>&1 || lint=fail
  done
  record "project=$dir toolchain=wp lint=$lint files_checked=$n build=none tests=none"
  [ "$lint" = fail ] && red "$dir: PHP syntax error"
  return 0
}

cmd_run() {
  rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
  local found=0 dir kind out res
  case "$RESULTS_DIR" in /*) res="$RESULTS_DIR" ;; *) res="$ROOT/$RESULTS_DIR" ;; esac

  # Changed files: the workflow supplies a list (CHANGED_FILES_FILE, from the PR API);
  # locally, BASE_SHA works when the base commit is reachable. A list that exists but is
  # empty is a real empty diff. NO list (the API call failed) is `changed_files=unavailable`:
  # every PHP file is then syntax-checked and no sub-project is skipped. Until 23 Sep 2026
  # the build job lacked `pull-requests: read`, the call failed with a 403 on every PR, and
  # an empty list was read as "nothing changed".
  # Absolute path: build_php and php_files_to_lint read it from inside a sub-project.
  if [ -n "${CHANGED_FILES_FILE:-}" ] && [ -f "$CHANGED_FILES_FILE" ]; then
    CHANGED_FILE="$res/changed-files.txt"
    if cp "$CHANGED_FILES_FILE" "$CHANGED_FILE"; then CHANGED_STATUS=ok; else CHANGED_FILE=""; fi
  elif [ -n "${BASE_SHA:-}" ]; then
    git fetch -q --depth=1 origin "$BASE_SHA" 2>/dev/null || true
    if git cat-file -e "$BASE_SHA" 2>/dev/null; then
      CHANGED_FILE="$res/changed-files.txt"
      if git diff --name-only "$BASE_SHA" HEAD > "$CHANGED_FILE" 2>/dev/null; then CHANGED_STATUS=ok; else CHANGED_FILE=""; fi
    fi
  fi
  [ "$CHANGED_STATUS" = ok ] || record "changed_files=unavailable (could not read the PR's file list: every PHP file is syntax-checked, no sub-project is skipped)"

  # A root manifest, lockfile or workspace config is shared by every sub-project: when the
  # PR changes one, no sub-project counts as untouched.
  local shared_changed=false
  [ "$CHANGED_STATUS" = ok ] && grep -qE '^(package\.json|package-lock\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|\.npmrc|\.nvmrc|\.node-version|tsconfig[^/]*\.json|turbo\.json|nx\.json|composer\.(json|lock))$' "$CHANGED_FILE" \
    && shared_changed=true

  while IFS=$'\t' read -r dir kind; do
    [ -z "$dir" ] && continue
    found=$((found+1))
    out="$res/$(slug "$dir")"; mkdir -p "$out"
    # a sub-project the PR did not touch is not rebuilt
    if [ "$dir" != "." ] && [ "$CHANGED_STATUS" = ok ] && [ "$shared_changed" = false ] && [ -z "$(changed_files_for "$dir")" ]; then
      record "project=$dir toolchain=${kind%-covered} build=skipped reason=no-changed-files"; continue
    fi
    log "== $dir ($kind)"
    case "$kind" in
      node) build_node "$dir" "$out" ;;
      php)  build_php  "$dir" "$out" ;;
      wp)   build_wp   "$dir" "$out" ;;
      node-covered) record "project=$dir toolchain=node build=covered-by-root" ;;
    esac
  done < <(discover)

  [ "$found" = 0 ] && record "project=. toolchain=none build=skipped reason=no-package.json-or-composer.json-found"

  local overall=green
  [ -n "$RED_REASONS" ] && overall=red
  SUMMARY="${SUMMARY}overall=$overall${RED_REASONS:+ reasons=${RED_REASONS% }}"$'\n'
  printf '%s' "$SUMMARY" > "$RESULTS_DIR/summary.txt"
  # trim logs so the reviewer's artifact stays small
  find "$RESULTS_DIR" -name '*.log' -size +400k -exec sh -c 'tail -c 400000 "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;
  printf '%s' "$SUMMARY"
  [ "$overall" = green ]
}

case "${1:-}" in
  detect) cmd_detect ;;
  run)    cmd_run ;;
  *) echo "usage: build.sh detect|run" >&2; exit 2 ;;
esac
