#!/usr/bin/env bash
set -euo pipefail
apt-get update -qq
apt-get install -yqq wget unzip libyaml-dev build-essential curl git libssl-dev libreadline-dev zlib1g-dev xz-utils ca-certificates wget libpq-dev vim postgresql libvips libvips-dev ffmpeg

pg_ctlcluster --skip-systemctl-redirect 16 main start
su - postgres -c "createuser -s $(whoami)"
