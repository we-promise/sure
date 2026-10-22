#!/usr/bin/env bash
#MISE description="Install locked dependencies, prepare databases, and build assets"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

[ -e .env.local ] || cp .env.local.example .env.local
# The test helper supplies its defaults. The optional test template contains
# provider overrides and must only be copied/configured deliberately.

BUNDLE_FROZEN=true bundle install
npm ci

if [ "${SKIP_DB_SETUP:-0}" != "1" ]; then
  if [ -n "${DATABASE_URL:-}" ] || [ -n "${POSTGRES_DB:-}" ]; then
    echo 'Automatic setup needs separate development/test databases. Unset DATABASE_URL and POSTGRES_DB, or use SKIP_DB_SETUP=1 and prepare your databases explicitly.' >&2
    exit 1
  fi
  bash .mise/tasks/services.sh
  for environment in development test; do
    RAILS_ENV="$environment" bundle exec ruby -r ./config/environment -e \
      'Rails.application.load_tasks; ActiveRecord.dump_schema_after_migration = false; Rake::Task["db:prepare"].invoke'
  done
fi

# Design-token CSS is checked in; do not rewrite tracked files during setup.
bin/rails tailwindcss:build
