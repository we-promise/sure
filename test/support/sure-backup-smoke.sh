#!/usr/bin/env bash
set -euo pipefail

image=${1:?Pass a Sure image with PostgreSQL client tools}
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project="sure-backup-test-$$"
network="$project"
volume="$project-backups"
servers=()

cleanup() {
  if (( ${#servers[@]} )); then
    docker rm -fv "${servers[@]}" >/dev/null
  fi
  docker volume rm "$volume" >/dev/null
  docker network rm "$network" >/dev/null
}

db() {
  local major=$1
  shift
  docker exec -i "$project-pg$major" psql -X -v ON_ERROR_STOP=1 -U sure -d sure_test "$@"
}

backup() {
  local major=$1
  shift
  docker run --rm --network "$network" --user 0 \
    --env "POSTGRES_HOST=$project-pg$major" \
    --env POSTGRES_DB=sure_test --env POSTGRES_USER=sure --env POSTGRES_PASSWORD=test \
    --mount "type=volume,source=$volume,target=/backups" \
    --mount "type=bind,source=$repo/bin/sure-backup,target=/usr/local/bin/sure-backup,readonly" \
    --entrypoint /usr/local/bin/sure-backup "$image" "$@"
}

backup_id() {
  backup "$1" list | awk -v prefix="pg$1/" 'index($1, prefix) == 1 { print $1 }'
}

assert_row() {
  local actual
  actual=$(db "$1" -Atc 'SELECT description FROM backup_test')
  if [[ "$actual" != "$2" ]]; then
    printf 'PostgreSQL %s: expected %s, got %s\n' "$1" "$2" "$actual" >&2
    exit 1
  fi
}

trap cleanup EXIT
docker network create --internal "$network" >/dev/null
docker volume create "$volume" >/dev/null

for major in 16 18 19; do
  server="$project-pg$major"
  docker run -d --name "$server" --network "$network" \
    --env POSTGRES_DB=sure_test --env POSTGRES_USER=sure --env POSTGRES_PASSWORD=test \
    "postgres:$major-trixie" >/dev/null
  servers+=("$server")
  for attempt in {1..30}; do
    if docker exec "$server" pg_isready -h 127.0.0.1 -U sure -d sure_test >/dev/null; then
      break
    fi
    if (( attempt == 30 )); then
      docker logs "$server"
      exit 1
    fi
    sleep 1
  done

  db "$major" <<SQL
CREATE EXTENSION pgcrypto;
CREATE TABLE schema_migrations (version varchar PRIMARY KEY);
INSERT INTO schema_migrations VALUES ('1');
CREATE TABLE backup_test (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), description text NOT NULL);
INSERT INTO backup_test (description) VALUES ('from PostgreSQL $major');
SQL

  backup "$major" create --version "pg$major"
  db "$major" -c "UPDATE backup_test SET description = 'changed'"
  backup "$major" restore "$(backup_id "$major")" --yes
  assert_row "$major" "from PostgreSQL $major"
done

if output=$(backup 16 restore "$(backup_id 19)" --yes 2>&1); then
  printf 'A PostgreSQL 19 backup was accepted by PostgreSQL 16\n' >&2
  exit 1
fi
printf '%s\n' "$output"
[[ "$output" == *"this backup is from PostgreSQL 19, but the target is PostgreSQL 16"* ]]
assert_row 16 "from PostgreSQL 16"

for major in 16 18; do
  backup 19 restore "$(backup_id "$major")" --yes
  assert_row 19 "from PostgreSQL $major"
done
