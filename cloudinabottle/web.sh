#!/bin/bash
# Rails web process (Puma). Runs as the rails user via supervisord.
set -euo pipefail

# shellcheck disable=SC1090
. "$SURE_ENV_FILE"

# Wait for PostgreSQL to accept TCP connections before migrating.
until pg_isready -h 127.0.0.1 -p 5432 -q; do sleep 1; done

cd /rails
./bin/rails db:prepare

# Signal the Sidekiq wrapper that migrations are done. The marker lives on
# tmpfs (recreated by the entrypoint every boot), so a stale marker can never
# let the worker start ahead of migrations after an upgrade.
touch "$SURE_RUN_DIR/db-ready"

# docker-entrypoint adds jemalloc and re-runs db:prepare (fast no-op),
# matching the stock self-hosted image's boot path.
exec /rails/bin/docker-entrypoint ./bin/rails server
