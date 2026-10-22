#!/usr/bin/env bash
#MISE description="Start isolated, loopback-only development PostgreSQL and Redis"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

if [ "$SURE_MANAGED_SERVICES" = "0" ]; then
  pg_isready -h "$DB_HOST" -p "$DB_PORT"
  redis-cli -u "$REDIS_URL" ping
  exit
fi

if [ "$DB_HOST" != "127.0.0.1" ] || [ "$REDIS_URL" != "redis://127.0.0.1:$SURE_REDIS_PORT/1" ]; then
  echo 'For existing/external services set SURE_MANAGED_SERVICES=0 and configure DB_HOST, DB_PORT and REDIS_URL.' >&2
  exit 1
fi
for port in "$DB_PORT" "$SURE_REDIS_PORT"; do
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
    echo "Invalid development port: $port" >&2
    exit 1
  fi
done

mkdir -p "$SURE_SERVICE_DIR"
pgdata="$SURE_SERVICE_DIR/postgres"
if ! pg_ctl -D "$pgdata" status >/dev/null 2>&1; then
  if pg_isready -h "$DB_HOST" -p "$DB_PORT" >/dev/null 2>&1; then
    echo "PostgreSQL port $DB_PORT is already occupied; choose another DB_PORT." >&2
    exit 1
  fi
  if [ ! -f "$pgdata/PG_VERSION" ]; then
    initdb -D "$pgdata" -U "$POSTGRES_USER" -A trust --no-locale -E UTF8
  fi
  pg_ctl -D "$pgdata" -l "$SURE_SERVICE_DIR/postgres.log" \
    -o "-h 127.0.0.1 -p $DB_PORT -k ''" -w start
fi

redis_pidfile="$SURE_SERVICE_DIR/redis.pid"
if redis-cli -h 127.0.0.1 -p "$SURE_REDIS_PORT" ping >/dev/null 2>&1; then
  running_pid=$(redis-cli -h 127.0.0.1 -p "$SURE_REDIS_PORT" info server | tr -d '\r' | sed -n 's/^process_id://p')
  if [ ! -f "$redis_pidfile" ] || [ "$(cat "$redis_pidfile")" != "$running_pid" ]; then
    echo "Redis port $SURE_REDIS_PORT is already occupied; choose another SURE_REDIS_PORT and REDIS_URL." >&2
    exit 1
  fi
else
  redis-server --bind 127.0.0.1 --port "$SURE_REDIS_PORT" --daemonize yes \
    --dir "$SURE_SERVICE_DIR" --pidfile "$redis_pidfile" --logfile "$SURE_SERVICE_DIR/redis.log"
fi
pg_isready -h "$DB_HOST" -p "$DB_PORT"
redis-cli -u "$REDIS_URL" ping
