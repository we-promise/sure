#!/bin/bash
# One-shot PostgreSQL provisioning, run by supervisord after the cluster
# starts (priority 20, between postgres/redis and web/worker). Idempotent.
set -euo pipefail

# shellcheck disable=SC1090
. "$SURE_ENV_FILE"

until pg_isready -h /tmp -U postgres -q; do sleep 1; done

# Role + database, created only when missing. The password is (re)applied
# every boot so it always tracks secrets.env. It never touches the command
# line or psql history: it goes in as a psql variable.
psql -h /tmp -U postgres -v ON_ERROR_STOP=1 -v pw="$POSTGRES_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'sure') THEN
    CREATE ROLE sure LOGIN;
  END IF;
END
$$;
ALTER ROLE sure WITH PASSWORD :'pw';
SELECT 'CREATE DATABASE sure_production OWNER sure'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'sure_production')\gexec
SQL

# pgvector is installed in the image and pre-enabled so the optional
# document-search vector store (VECTOR_STORE_PROVIDER=pgvector) works
# without manual steps. Harmless when unused.
psql -h /tmp -U postgres -d sure_production -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS vector'

echo "[sure] database provisioned (role sure, db sure_production)"
