#!/bin/bash
# Sidekiq worker process. Runs as the rails user via supervisord.
set -euo pipefail

# shellcheck disable=SC1090
. "$SURE_ENV_FILE"

# Never process jobs against an unmigrated schema: wait for the web wrapper
# to finish db:prepare this boot.
until [ -f "$SURE_RUN_DIR/db-ready" ]; do sleep 2; done

cd /rails
# bin/docker-entrypoint only migrates for `./bin/rails server`; here it just
# adds jemalloc, matching the stock worker's runtime.
exec /rails/bin/docker-entrypoint bundle exec sidekiq
