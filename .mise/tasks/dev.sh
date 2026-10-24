#!/usr/bin/env bash
#MISE description="Start services, Rails, Sidekiq, and the noninteractive Tailwind watcher"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"
bash .mise/tasks/services.sh
export PORT="${PORT:-3000}"
exec bundle exec foreman start -d "$MISE_PROJECT_ROOT" -f .mise/Procfile.dev
