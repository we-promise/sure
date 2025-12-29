#!/usr/bin/env bash
set -euo pipefail

if ! command -v bundle >/dev/null 2>&1; then
  echo "bundle not found in PATH; run 'mise install' first."
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm not found in PATH; run 'mise install' first."
  exit 1
fi

if [ ! -f .env.local ]; then
  cp .env.local.example .env.local
fi

bundle check >/dev/null 2>&1 || bundle install
npm install

if [ "${SKIP_DB_SETUP:-0}" != "1" ]; then
  bin/rails db:prepare
fi
