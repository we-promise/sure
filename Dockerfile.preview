# syntax = docker/dockerfile:1

# Preview Dockerfile for Cloudflare Containers
# Includes PostgreSQL and Redis for self-contained development testing

ARG RUBY_VERSION=3.4.7
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Install base packages including PostgreSQL and Redis servers
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y \
       curl libvips postgresql postgresql-client redis-server libyaml-0-2 procps sudo \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set development environment
ARG BUILD_COMMIT_SHA
ENV RAILS_ENV="development" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUILD_COMMIT_SHA=${BUILD_COMMIT_SHA}

# Build stage
FROM base AS build

RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y build-essential libpq-dev git pkg-config libyaml-dev \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install \
    && rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git \
    && bundle exec bootsnap precompile --gemfile -j 0

COPY . .

RUN bundle exec bootsnap precompile -j 0 app/ lib/

# Precompile assets
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage
FROM base

# Create rails user and configure PostgreSQL/Redis permissions
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    echo "rails ALL=(ALL) NOPASSWD: /usr/bin/pg_ctlcluster, /usr/bin/redis-server" >> /etc/sudoers.d/rails

# Configure PostgreSQL to allow local connections
RUN echo "local all all trust" > /etc/postgresql/*/main/pg_hba.conf && \
    echo "host all all 127.0.0.1/32 trust" >> /etc/postgresql/*/main/pg_hba.conf && \
    echo "host all all ::1/128 trust" >> /etc/postgresql/*/main/pg_hba.conf

# Create database directory with correct permissions
RUN mkdir -p /var/run/postgresql && \
    chown -R postgres:postgres /var/run/postgresql && \
    chmod 2775 /var/run/postgresql

# Copy built artifacts
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Create preview entrypoint script inline
RUN cat > /rails/bin/preview-entrypoint << 'ENTRYPOINT_EOF'
#!/bin/bash
set -e

# Start Redis
echo "Starting Redis..."
sudo redis-server --daemonize yes --bind 127.0.0.1

# Wait for Redis to be ready
echo "Waiting for Redis to be ready..."
for i in {1..10}; do
  if redis-cli ping > /dev/null 2>&1; then
    echo "Redis is ready"
    break
  fi
  sleep 1
done

# Start PostgreSQL
echo "Starting PostgreSQL..."
sudo pg_ctlcluster 15 main start || sudo pg_ctlcluster 16 main start || sudo pg_ctlcluster 17 main start

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
  if pg_isready -h localhost -U postgres > /dev/null 2>&1; then
    echo "PostgreSQL is ready"
    break
  fi
  sleep 1
done

# Create database user and database if they don't exist
echo "Setting up database..."
psql -h localhost -U postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='rails'" | grep -q 1 || \
  psql -h localhost -U postgres -c "CREATE USER rails WITH SUPERUSER PASSWORD 'rails';"

psql -h localhost -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='sure_development'" | grep -q 1 || \
  psql -h localhost -U postgres -c "CREATE DATABASE sure_development OWNER rails;"

# Set DATABASE_URL if not already set
export DATABASE_URL="${DATABASE_URL:-postgres://rails:rails@localhost:5432/sure_development}"

# Set REDIS_URL if not already set
export REDIS_URL="${REDIS_URL:-redis://localhost:6379/0}"

# Generate SECRET_KEY_BASE if not set
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -hex 64)}"

# Run database migrations
echo "Running database migrations..."
./bin/rails db:prepare

# Execute the main command
echo "Starting Rails server..."
exec "$@"
ENTRYPOINT_EOF
RUN chmod 755 /rails/bin/preview-entrypoint && chown rails:rails /rails/bin/preview-entrypoint

USER 1000:1000

ENTRYPOINT ["/rails/bin/preview-entrypoint"]

EXPOSE 3000
CMD ["./bin/rails", "server", "-b", "0.0.0.0"]
