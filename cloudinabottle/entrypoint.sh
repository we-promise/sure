#!/bin/bash
# Cloud in a Bottle all-in-one entrypoint for Sure.
# Runs as container root; drops privileges per process via supervisord.
set -euo pipefail

# Cloud in a Bottle injects BOTTLE_APP_DATA_DIR for apps that request
# app_data (default on). Fall back to the conventional path for plain
# `docker run` testing outside a zone.
DATA_DIR="${BOTTLE_APP_DATA_DIR:-/data/app_data/sure}"
SECRETS_FILE="$DATA_DIR/secrets.env"
RUN_DIR="/tmp/sure-run"
ENV_FILE="$RUN_DIR/sure.env"

mkdir -p "$DATA_DIR/postgres" "$DATA_DIR/redis" "$DATA_DIR/storage" "$RUN_DIR"

# First boot only: generate SECRET_KEY_BASE and the database password, then
# persist them in the app's permanent data dir. Restarts, rebuilds and the
# instance's backup app all keep this file, so encrypted credentials and
# sessions survive. It is never written into the image or the repo.
if [ ! -f "$SECRETS_FILE" ]; then
  umask 077
  {
    printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -hex 64)"
    printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)"
  } > "$SECRETS_FILE"
  echo "[sure] first boot: generated secrets in $SECRETS_FILE"
fi
chmod 600 "$SECRETS_FILE"
# shellcheck disable=SC1090
. "$SECRETS_FILE"

# The zone tells us our subdomain and domain; derive the public hostname so
# emails, WebAuthn/passkeys and links point at the real URL. Stays correct
# automatically if the app is renamed.
APP_DOMAIN_VALUE=""
if [ -n "${BOTTLE_APP_NAME:-}" ] && [ -n "${BOTTLE_ZONE_DOMAIN:-}" ]; then
  APP_DOMAIN_VALUE="${BOTTLE_APP_NAME}.${BOTTLE_ZONE_DOMAIN}"
fi

# Runtime env for the Rails web + Sidekiq wrappers. 0640 root:rails - only
# the app processes can read it. PostgreSQL and Redis don't need it: their
# settings live in the supervisord config and provision script.
{
  printf 'RAILS_ENV=%s\n' "production"
  printf 'SELF_HOSTED=%s\n' "true"
  printf 'SECRET_KEY_BASE=%s\n' "$SECRET_KEY_BASE"
  printf 'DB_HOST=%s\n' "127.0.0.1"
  printf 'DB_PORT=%s\n' "5432"
  printf 'POSTGRES_USER=%s\n' "sure"
  printf 'POSTGRES_DB=%s\n' "sure_production"
  printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
  printf 'REDIS_URL=%s\n' "redis://127.0.0.1:6379/1"
  # The CiaB router terminates TLS and proxies to this container over HTTP.
  printf 'RAILS_FORCE_SSL=%s\n' "false"
  printf 'RAILS_ASSUME_SSL=%s\n' "true"
  printf 'APP_DOMAIN=%s\n' "$APP_DOMAIN_VALUE"
  printf 'PORT=%s\n' "3000"
  # Match the conservative self-hosted defaults (see sure-render-templates);
  # everything runs in one memory-capped container here.
  printf 'WEB_CONCURRENCY=%s\n' "${WEB_CONCURRENCY:-1}"
  printf 'RAILS_MAX_THREADS=%s\n' "${RAILS_MAX_THREADS:-3}"
} > "$ENV_FILE"
chown root:rails "$ENV_FILE"
chmod 640 "$ENV_FILE"

# ActiveStorage's local disk service is fixed at /rails/storage; point it at
# the persistent tier. Only replace the directory while it is empty (fresh
# image), never over real data.
if [ -d /rails/storage ] && [ ! -L /rails/storage ]; then
  if [ -z "$(find /rails/storage -mindepth 1 -not -name '.keep' -print -quit)" ]; then
    rm -rf /rails/storage
    ln -s "$DATA_DIR/storage" /rails/storage
  else
    echo "[sure] WARNING: /rails/storage is not empty; uploads will NOT persist" >&2
  fi
fi

chown -R postgres:postgres "$DATA_DIR/postgres"
chown -R redis:redis "$DATA_DIR/redis"
chown -R rails:rails "$DATA_DIR/storage"
chmod 700 "$DATA_DIR/postgres"

# First boot only: initialize the PostgreSQL cluster. Local (same-container)
# connections are trusted so the provision step can connect as the postgres
# superuser; anything connecting over TCP - which is what Rails does - needs
# the SCRAM password from secrets.env.
if [ ! -s "$DATA_DIR/postgres/PG_VERSION" ]; then
  echo "[sure] first boot: initializing PostgreSQL cluster"
  su -s /bin/bash postgres -c \
    "/usr/lib/postgresql/16/bin/initdb -D \"$DATA_DIR/postgres\" -E UTF8 --auth-local=trust --auth-host=scram-sha-256"
fi

# Consumed by supervisord.conf (%(ENV_...)s) and the wrapper scripts.
export SURE_DATA_DIR="$DATA_DIR"
export SURE_ENV_FILE="$ENV_FILE"
export SURE_RUN_DIR="$RUN_DIR"

exec supervisord -c /opt/cloudinabottle/supervisord.conf
