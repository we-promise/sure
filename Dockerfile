# syntax = docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
ARG RUBY_VERSION=3.4.13
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim-trixie AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
# poppler-utils provides pdftoppm, required for the PDF vision processing path
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y curl libvips postgresql-client libyaml-0-2 procps libjemalloc2 poppler-utils \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ARG BUILD_COMMIT_SHA
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    BUILD_COMMIT_SHA=${BUILD_COMMIT_SHA}

FROM base AS scalable-cli
ARG TARGETARCH
# Checksums are pinned from Scalable's signed release manifest.
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) arch=x86_64; checksum=309b0f0211c02d28391bd5db5f7745c98d5a2f47830b698cc5efb8095e0f7678 ;; \
      arm64) arch=aarch64; checksum=ead8313fc7defe6fdebd11a32d315071f28432f2127d33459b032cae03cfe2e7 ;; \
      *) echo "Unsupported Scalable CLI architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    version=v1.3.0; \
    archive="/tmp/scalable-cli.tar.gz"; \
    curl -fsSL --retry 3 "https://github.com/ScalableCapital/scalable-cli/releases/download/${version}/sc-${version}-linux-${arch}-gnu.tar.gz" -o "$archive"; \
    printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -; \
    mkdir -p /opt/scalable-cli; \
    tar -xzf "$archive" --no-same-owner --strip-components=1 -C /opt/scalable-cli; \
    license=/opt/scalable-cli/LICENSE; \
    curl -fsSL --retry 3 "https://raw.githubusercontent.com/ScalableCapital/scalable-cli/7c41a668aa7dbce005cb2512e4be04e6640d07a0/LICENSE" -o "$license"; \
    printf '%s  %s\n' d17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc "$license" | sha256sum -c -

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y build-essential libpq-dev git pkg-config libyaml-dev \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install \
    && rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git \
    && bundle exec bootsnap precompile --gemfile -j 0

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile -j 0 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage for app image
FROM base

COPY --from=scalable-cli /opt/scalable-cli /opt/scalable-cli
ENV SCALABLE_CAPITAL_CLI_PATH=/usr/local/bin/sc

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    ln -s /opt/scalable-cli/sc "$SCALABLE_CAPITAL_CLI_PATH" && \
    install -d -m 0700 -o rails -g rails /home/rails/.config/scalable-cli && \
    printf '[auth]\nsession_backend = "file"\n' > /home/rails/.config/scalable-cli/config.toml && \
    chown rails:rails /home/rails/.config/scalable-cli/config.toml && \
    chmod 0600 /home/rails/.config/scalable-cli/config.toml
USER 1000:1000
RUN sc --version

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
