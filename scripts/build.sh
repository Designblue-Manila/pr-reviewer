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

# --------------------------------------------------------- project discovery ---

# Emits "<dir>\t<kind>" lines. kind = php | node | wp
# Root wins; otherwise every dir up to 3 deep holding composer.json or package.json.
# A dir with composer.json is php (its package.json is Vite assets, not a second project).
discover() {
  if [ -f composer.json ]; then echo -e ".\tphp"; return; fi
  if [ -f package.json ]; then echo -e ".\tnode"; return; fi
  if [ -d wp-content ] || ls wp-config*.php >/dev/null 2>&1; then echo -e ".\twp"; return; fi
  find . -mindepth 2 -maxdepth 4 \
       \( -name node_modules -o -name vendor -o -name .git -o -name dist -o -name .output -o -name .nuxt -o -name storage -o -name public \) -prune -o \
       \( -name composer.json -o -name package.json \) -print 2>/dev/null \
    | sed 's#^\./##' | sort \
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
  local dir="$1" v
  v="$(first_version "$(json_get "$dir/composer.json" require.php)")"
  case "$v" in ''|8) v="$PHP_DEFAULT" ;; esac
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
  local has_node=false has_php=false node_version="" php_version="" projects=""
  while IFS=$'\t' read -r dir kind; do
    [ -z "$dir" ] && continue
    projects="${projects}${dir}:${kind} "
    case "$kind" in
      node) has_node=true; [ -z "$node_version" ] && node_version="$(detect_node_version "$dir")" ;;
      php)  has_php=true;  [ -z "$php_version" ]  && php_version="$(detect_php_version "$dir")"
            # Laravel repos ship a package.json too; only set up Node if it is really used in CI
            ;;
      wp)   has_php=true;  [ -z "$php_version" ]  && php_version="$PHP_DEFAULT" ;;
    esac
  done < <(discover)
  echo "has_node=$has_node"
  echo "has_php=$has_php"
  echo "node_version=${node_version:-$NODE_DEFAULT}"
  echo "php_version=${php_version:-$PHP_DEFAULT}"
  echo "projects=${projects% }"
}

# --------------------------------------------------------------- run mode ---

CHANGED_FILE=""
SUMMARY=""
RED_REASONS=""

changed_files_for() {  # dir -> prints changed paths under dir (relative to repo root)
  local dir="$1"
  [ -z "$CHANGED_FILE" ] && return 0
  if [ "$dir" = "." ]; then cat "$CHANGED_FILE"; else grep -E "^${dir}/" "$CHANGED_FILE" || true; fi
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
  [ "${build:-none}" = fail ] && red "$dir: build failed"
  [ "${tests:-none}" = failed ] && red "$dir: tests failed"
  return 0
}

build_php() {
  local dir="$1" out="$2" phpv line install boot migrate tests db lint dbname
  phpv="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo none)"
  ( cd "$dir" || exit 1
    install=ok boot=none migrate=none tests=none db=none lint=ok

    # php -l on the changed PHP files (syntax errors before anything else)
    for f in $(changed_files_for "$dir" | grep -E '\.php$' || true); do
      rel="${f#"$dir"/}"; [ -f "$rel" ] || continue
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
    if [ "$install" = ok ]; then
      grep -qE '^APP_KEY=.+' .env || php artisan key:generate --force >>"$out/install.log" 2>&1 || true
      [ -f .env.testing ] && ! grep -qE '^APP_KEY=.+' .env.testing && set_env_kv .env.testing APP_KEY "$(grep -E '^APP_KEY=' .env | cut -d= -f2-)"
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
        if [ -f artisan ]; then run_timed php artisan test >"$out/test.log" 2>&1 && tests=passed || tests=failed
        elif [ -x vendor/bin/phpunit ]; then run_timed vendor/bin/phpunit >"$out/test.log" 2>&1 && tests=passed || tests=failed
        fi
        if [ "$tests" = failed ] && grep -qiE 'SQLSTATE\[HY000\] \[2002\]|could not find driver|Connection refused|Access denied for user|Unknown database|Unable to read key from file|No application encryption key' "$out/test.log"; then
          tests=unrunnable
        fi
        if [ "$tests" = passed ] || [ "$tests" = failed ]; then
          tl="$(grep -E '^\s*Tests:' "$out/test.log" | tail -1)"
          np="$(printf '%s' "$tl" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')"
          nf="$(printf '%s' "$tl" | grep -oE '[0-9]+ (failed|errors?)' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)"
          [ "$tests" = passed ] && [ -n "$np" ] && tests="passed:$np"
          [ "$tests" = failed ] && tests="failed:${nf:-?}/${np:-0}"
        fi
      fi
    fi
    { echo "install=$install"; echo "boot=$boot"; echo "migrate=$migrate"; echo "tests=$tests"; echo "db=$db"; echo "lint=$lint"; } > "$out/status.txt"
  )
  install="$(status_of "$out" install)"; lint="$(status_of "$out" lint)"; boot="$(status_of "$out" boot)"
  migrate="$(status_of "$out" migrate)"; tests="$(status_of "$out" tests)"; db="$(status_of "$out" db)"
  line="project=$dir toolchain=php php=$phpv install=${install:-fail} lint=${lint:-ok} boot=${boot:-none} migrate=${migrate:-none} tests=${tests:-none} db=${db:-none}"
  record "$line"
  [ "${install:-fail}" = fail ] && red "$dir: composer install failed"
  [ "${lint:-ok}" = fail ] && red "$dir: PHP syntax error"
  [ "${boot:-none}" = fail ] && red "$dir: application failed to boot"
  [ "${migrate:-none}" = fail ] && red "$dir: migrations failed on a fresh database"
  case "${tests:-none}" in failed*) red "$dir: tests failed" ;; esac
  return 0
}

build_wp() {
  local dir="$1" out="$2" lint=ok n=0 f rel
  for f in $(changed_files_for "$dir" | grep -E '\.php$' || true); do
    rel="${f#"$dir"/}"; [ -f "$rel" ] || continue
    n=$((n+1)); php -l "$rel" >>"$out/lint.log" 2>&1 || lint=fail
  done
  record "project=$dir toolchain=wp lint=$lint files_checked=$n build=none tests=none"
  [ "$lint" = fail ] && red "$dir: PHP syntax error"
  return 0
}

cmd_run() {
  rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
  local found=0 dir kind out

  # Changed files: the workflow supplies a list (CHANGED_FILES_FILE, from the PR API);
  # locally, BASE_SHA works when the base commit is reachable.
  if [ -n "${CHANGED_FILES_FILE:-}" ] && [ -s "$CHANGED_FILES_FILE" ]; then
    CHANGED_FILE="$RESULTS_DIR/changed-files.txt"
    cp "$CHANGED_FILES_FILE" "$CHANGED_FILE"
  elif [ -n "${BASE_SHA:-}" ]; then
    git fetch -q --depth=1 origin "$BASE_SHA" 2>/dev/null || true
    if git cat-file -e "$BASE_SHA" 2>/dev/null; then
      CHANGED_FILE="$RESULTS_DIR/changed-files.txt"
      git diff --name-only "$BASE_SHA" HEAD > "$CHANGED_FILE" 2>/dev/null || CHANGED_FILE=""
    fi
  fi

  while IFS=$'\t' read -r dir kind; do
    [ -z "$dir" ] && continue
    found=$((found+1))
    out="$ROOT/$RESULTS_DIR/$(slug "$dir")"; mkdir -p "$out"
    # a sub-project the PR did not touch is not rebuilt
    if [ "$dir" != "." ] && [ -n "$CHANGED_FILE" ] && [ -z "$(changed_files_for "$dir")" ]; then
      record "project=$dir toolchain=$kind build=skipped reason=no-changed-files"; continue
    fi
    log "== $dir ($kind)"
    case "$kind" in
      node) build_node "$dir" "$out" ;;
      php)  build_php  "$dir" "$out" ;;
      wp)   build_wp   "$dir" "$out" ;;
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
