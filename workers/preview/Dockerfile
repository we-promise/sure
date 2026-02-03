# syntax = docker/dockerfile:1

# Preview Dockerfile for Cloudflare Containers
# Includes PostgreSQL for self-contained development testing

ARG RUBY_VERSION=3.4.7
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Install base packages including PostgreSQL server
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y \
       curl libvips postgresql postgresql-client libyaml-0-2 procps sudo \
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

# Create rails user and configure PostgreSQL
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    echo "rails ALL=(ALL) NOPASSWD: /usr/bin/pg_ctlcluster" >> /etc/sudoers.d/rails

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

# Copy preview entrypoint
COPY --chown=rails:rails --chmod=755 workers/preview/docker-entrypoint.sh /rails/bin/preview-entrypoint

USER 1000:1000

ENTRYPOINT ["/rails/bin/preview-entrypoint"]

EXPOSE 3000
CMD ["./bin/rails", "server", "-b", "0.0.0.0"]
