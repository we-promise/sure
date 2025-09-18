#!/usr/bin/env bash
set -euo pipefail

# Disable profile loading to avoid environment errors
export ENV=""
export BASH_ENV=""

echo "Installing PostgreSQL and dependencies..."
apt-get update -qq
apt-get install -yqq wget unzip libyaml-dev build-essential curl git libssl-dev libreadline-dev zlib1g-dev xz-utils ca-certificates libpq-dev vim postgresql libvips libvips-dev ffmpeg

echo "Starting PostgreSQL cluster..."
pg_ctlcluster --skip-systemctl-redirect 16 main start

echo "Creating database user for $(whoami)..."
# Use runuser instead of su to avoid profile loading issues
runuser -l postgres -c "createuser -s $(whoami)" 2>/dev/null

echo "PostgreSQL setup completed successfully!"
