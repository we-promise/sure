#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:-$(pwd)}"
cd "$REPO_DIR"

RUBY_VERSION="$(tr -d '[:space:]' < .ruby-version)"
BUNDLER_VERSION="$(awk '/^BUNDLED WITH$/{getline; gsub(/^[[:space:]]+/, ""); print; exit}' Gemfile.lock)"

if [[ -z "$RUBY_VERSION" ]]; then
  echo "Failed to read Ruby version from .ruby-version" >&2
  exit 1
fi

if [[ -z "$BUNDLER_VERSION" ]]; then
  echo "Failed to read Bundler version from Gemfile.lock" >&2
  exit 1
fi

apt-get install -y --no-install-recommends \
  rbenv ruby-build libreadline-dev libgdbm-dev libgdbm-compat-dev bison

mkdir -p /root/.rbenv/plugins
rm -rf /root/.rbenv/plugins/ruby-build
git clone --depth=1 https://github.com/rbenv/ruby-build.git /root/.rbenv/plugins/ruby-build

export RBENV_ROOT=/root/.rbenv
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init -)"
export RUBY_BUILD_CACHE_PATH=/root/.cache/ruby-build

rbenv install -s "$RUBY_VERSION"
rbenv global "$RUBY_VERSION"
rbenv rehash

gem install bundler -v "$BUNDLER_VERSION" --no-document
rbenv rehash

ruby -v
bundle -v
