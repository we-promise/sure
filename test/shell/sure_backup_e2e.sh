#!/bin/sh
# End-to-end tests for `bin/sure-backup upgrade-postgres`, `restore` and the
# PostgreSQL version check in compose.example.yml.
#
#   sh test/shell/sure_backup_e2e.sh
#
# Needs Docker with the Compose plugin; takes a few minutes. It uses the real
# compose.example.yml. No Sure image is built: a postgres:18 container stands
# in for `web` and `worker`, which is all sure-backup needs from them (the
# PostgreSQL client tools, the database settings and the storage volume).
# Everything it creates is named sbe2e<pid>-* and removed at the end.

set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SB="${REPO}/bin/sure-backup"
RUN="sbe2e$$"
WORK=$(mktemp -d)
SEED="${RUN}-seed"
SCHEMA=20260101000000
failures=0

cleanup() {
  for dir in "$WORK"/*/; do
    [ -f "${dir}compose.yml" ] && (cd "$dir" && docker compose down -v --remove-orphans >/dev/null 2>&1)
  done
  docker ps -aq --filter "name=${RUN}" | xargs -r docker rm -f >/dev/null 2>&1
  docker network ls -q --filter "name=${RUN}" | xargs -r docker network rm >/dev/null 2>&1
  docker volume rm "$SEED" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

section() { printf '\n== %s\n' "$*"; }
pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
# check DESCRIPTION COMMAND...: passes when COMMAND succeeds.
check() {
  desc=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
# check_eq DESCRIPTION EXPECTED ACTUAL
check_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
# check_has DESCRIPTION NEEDLE HAYSTACK
check_has() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *)
      fail "$1 (no '$2' in the output below)"
      printf '%s\n' "$3" | sed 's/^/        | /'
      ;;
  esac
}

# --- helpers -----------------------------------------------------------------

vol() { docker run --rm -v "$1:/v" alpine sh -c "$2"; }
vol_ls() { vol "$1" 'ls -A /v | sort | tr "\n" " "'; }

# wait_tcp CONTAINER: a new server first runs a temporary one on a socket only.
wait_tcp() {
  i=0
  until docker exec "$1" pg_isready -q -h 127.0.0.1 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || return 1
    sleep 1
  done
}

# old_server VOLUME PGDATA_UNDER_VOLUME SQL [DATABASE]: runs SQL on the
# PostgreSQL 16 data.
old_server() {
  docker run -d --rm --name "${RUN}-tmp" -v "$1:/pg" -e "PGDATA=/pg$2" postgres:16 >/dev/null
  wait_tcp "${RUN}-tmp" && docker exec "${RUN}-tmp" psql -X -q -U sure_user -d "${4:-postgres}" -c "$3"
  docker stop "${RUN}-tmp" >/dev/null
}

# write_override DIR [broken-db]: the stand-in web and worker; optionally a db
# service that cannot start.
write_override() {
  cat > "$1/compose.override.yml" <<'EOF'
services:
  web:
    image: postgres:18
    entrypoint: ["sleep", "infinity"]
    ports: !reset []
  worker:
    image: postgres:18
    entrypoint: ["sleep", "infinity"]
EOF
  [ "${2:-}" = broken-db ] || return 0
  cat >> "$1/compose.override.yml" <<'EOF'
  db:
    command: ["postgres", "-c", "no_such_setting=1"]
EOF
}

# new_project NAME LAYOUT: a compose project on the current example file,
# whose volume holds PostgreSQL 16 data in LAYOUT (root, data or versioned).
new_project() {
  dir="${WORK}/$1"
  project="${RUN}-$1"
  volume="${project}_postgres-data"
  mkdir -p "$dir"
  cp "${REPO}/compose.example.yml" "${dir}/compose.yml"
  printf 'COMPOSE_PROJECT_NAME=%s\nSECRET_KEY_BASE=test\nOPENAI_ACCESS_TOKEN=\n' "$project" > "${dir}/.env"
  write_override "$dir"
  cd "$dir" || exit 1
  docker compose create web >/dev/null 2>&1 || { fail "create the $1 project"; return 1; }
  case "$2" in
    root) dest=/v ;;
    data) dest=/v/data ;;
    versioned) dest=/v/16/docker ;;
  esac
  docker run --rm -v "${SEED}:/s:ro" -v "${volume}:/v" alpine sh -c \
    "mkdir -p $dest && cp -a /s/. $dest/ && chown 999:999 $dest && chmod 700 $dest"
  # What the web container writes at boot, and an uploaded file.
  vol "${project}_app-storage" \
    "printf 'SURE_VERSION=0.0.0-test\nSURE_SCHEMA_VERSION=${SCHEMA}\n' > /v/.sure-runtime; echo uploaded > /v/upload.txt"
}

upgrade() { sh "$SB" upgrade-postgres --yes 2>&1; }
db_sql() { docker compose exec -T db psql -X -q -t -A -U sure_user -d "${2:-sure_production}" -c "$1" 2>&1; }
canary() { db_sql "SELECT string_agg(v, ',' ORDER BY v) FROM e2e_canary"; }
databases() { db_sql "SELECT string_agg(datname || ':' || datallowconn, ' ' ORDER BY datname) FROM pg_database WHERE NOT datistemplate" postgres; }

check_upgraded() {
  check_has "$1: the server is PostgreSQL 18" "18." "$(db_sql 'SHOW server_version')"
  check_eq "$1: the data came across" "from-16" "$(canary)"
  check_eq "$1: the volume holds 18/ and pg16-old/" "18 pg16-old " "$(vol_ls "$volume")"
  check_eq "$1: uploaded files are still there" "uploaded" "$(vol "${project}_app-storage" 'cat /v/upload.txt')"
}

# example_default NAME: the default compose.example.yml gives ${NAME:-default},
# so the seed has the credentials the example's services will use.
example_default() {
  sed -n "s/.*\${$1:-\([^}]*\)}.*/\1/p" "${REPO}/compose.example.yml" | head -n 1
}

# --- seed: a PostgreSQL 16 cluster as an older Sure would have left it ---------

section "Seed PostgreSQL 16 data"
docker volume create "$SEED" >/dev/null
docker run -d --rm --name "${RUN}-seed" -v "${SEED}:/var/lib/postgresql/data" \
  -e "POSTGRES_USER=$(example_default POSTGRES_USER)" \
  -e "POSTGRES_PASSWORD=$(example_default POSTGRES_PASSWORD)" \
  -e "POSTGRES_DB=$(example_default POSTGRES_DB)" \
  postgres:16 >/dev/null
if wait_tcp "${RUN}-seed" && docker exec "${RUN}-seed" psql -X -q -U sure_user -d sure_production -c "
    CREATE TABLE schema_migrations (version varchar PRIMARY KEY);
    INSERT INTO schema_migrations VALUES ('${SCHEMA}');
    CREATE TABLE e2e_canary (v text);
    INSERT INTO e2e_canary VALUES ('from-16');"; then
  pass "seed created"
else
  fail "seed created"
fi
docker stop "${RUN}-seed" >/dev/null
[ "$failures" -eq 0 ] || exit 1

# --- 1. data at the volume root (the layout older compose files produce) ------

section "1. Root layout: version check, upgrade, rerun"
new_project root root
check "starting PostgreSQL 18 on 16 data is refused" sh -c '! docker compose up -d db'
check_has "the version check names the upgrade command" "sure-backup upgrade-postgres" "$(docker compose logs db-version-check 2>&1)"
check_eq "the refused start changed nothing" "from-16" "$(old_server "$volume" "" "COPY e2e_canary TO STDOUT" sure_production)"

out=$(upgrade)
check_has "upgrade succeeds" "Sure now runs on PostgreSQL 18" "$out"
check_upgraded root
check_eq "no upgrade marker is left" "" "$(vol "$volume" 'ls -A /v | grep sure-upgrade || true')"
check_eq "the temporary server and network are gone" "" \
  "$(docker ps -aq --filter "name=${project}-pg-upgrade"; docker network ls -q --filter "name=${project}_pg-upgrade")"
check_has "a second run does nothing" "already on PostgreSQL 18" "$(upgrade)"

section "2. Restore (on the upgraded project)"
db_sql "INSERT INTO e2e_canary VALUES ('later')" >/dev/null
check_has "restore refuses while the app runs" "the app is running" "$(sh "$SB" restore latest --yes 2>&1)"
docker compose stop web worker >/dev/null 2>&1

docker compose exec -d db psql -U sure_user -d sure_production -c "SELECT pg_sleep(120)" >/dev/null 2>&1
sleep 2
check_has "restore refuses while a session is open" "other connection(s)" "$(sh "$SB" restore latest --yes 2>&1)"
check_eq "the refused restore changed nothing" "from-16,later" "$(canary)"

# A bundle whose dump is cut short, with matching checksums, so the load fails.
bundle=$(find backups -mindepth 2 -maxdepth 2 -name '*-pre-upgrade' | head -n 1)
docker run --rm -v "${dir}/backups:/b" alpine sh -c "
  cp -a /b/${bundle#backups/} /b/0.0.0-test/2000-01-01_000000-broken && cd /b/0.0.0-test/2000-01-01_000000-broken &&
  head -c \$(( \$(wc -c < db.dump) / 2 )) db.dump > db.cut && mv db.cut db.dump &&
  find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS"
out=$(sh "$SB" restore 0.0.0-test/2000-01-01_000000-broken --yes --force 2>&1)
check_has "a dump that fails to load is reported" "was left as it was" "$out"
check_eq "the failed restore changed nothing" "from-16,later" "$(canary)"
check_eq "the failed restore left no extra database" "postgres:true sure_production:true" "$(databases)"

docker compose exec -d db psql -U sure_user -d sure_production -c "SELECT pg_sleep(120)" >/dev/null 2>&1
sleep 2
out=$(sh "$SB" restore "${bundle#backups/}" --yes --force 2>&1)
check_has "restore --force succeeds with a session open" "Restored Sure" "$out"
check_eq "the database is the backup's again" "from-16" "$(canary)"
check_eq "every database is open and none is left over" "postgres:true sure_production:true" "$(databases)"

# --- 3. data in data/ : a failed upgrade, the way back, and a second attempt ---

section "3. data/ layout: PostgreSQL 18 fails to start, put back, upgrade again"
new_project data data
write_override "$dir" broken-db
out=$(upgrade)
check_has "the failure is reported" "did not start" "$out"
check_has "the failure prints the way back" "To go back to PostgreSQL 16" "$out"
check_has "the marker is in the volume" ".sure-upgrade-incomplete" "$(vol_ls "$volume")"

write_override "$dir"
docker compose stop >/dev/null 2>&1
check "the version check blocks the database meanwhile" sh -c '! docker compose up -d db'
check_has "and says why" "did not finish" "$(docker compose logs db-version-check 2>&1)"
out=$(upgrade)
check_has "a rerun does not upgrade again" "did not finish" "$out"
putback=$(printf '%s\n' "$out" | sed -n "s/.*alpine sh -c '\(.*\)'\$/\1/p" | head -n 1)
check "the rerun prints the put-back command" test -n "$putback"
docker compose stop >/dev/null 2>&1
check "the put-back command succeeds" vol "$volume" "$putback"
check_eq "the volume is as it was before" "data " "$(vol_ls "$volume")"
check "running it again is harmless" vol "$volume" "$putback"

out=$(upgrade)
check_has "the upgrade then succeeds" "Sure now runs on PostgreSQL 18" "$out"
check_upgraded data

# --- 4. data in 16/docker, on a server that holds another database ------------

section "4. <version>/docker layout: another database is refused, then upgrade"
new_project versioned versioned
old_server "$volume" /16/docker "CREATE DATABASE other"
out=$(upgrade)
check_has "another database stops the upgrade" "also holds other databases: other" "$out"
check_eq "nothing was moved" "16 " "$(vol_ls "$volume")"
check_eq "no backup-time leftovers" "" "$(docker ps -aq --filter "name=${project}-pg-upgrade")"

old_server "$volume" /16/docker "DROP DATABASE other"
out=$(upgrade)
check_has "the upgrade then succeeds" "Sure now runs on PostgreSQL 18" "$out"
check_upgraded versioned

# -----------------------------------------------------------------------------

printf '\n'
if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed."
