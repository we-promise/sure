# syntax = docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
ARG RUBY_VERSION=3.4.9
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
# poppler-utils provides pdftoppm, required for the PDF vision processing path
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y curl libvips postgresql-client libyaml-0-2 procps libjemalloc2 poppler-utils \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

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

# package noVNC's browser modules separately from the application runtime.
FROM base AS novnc-assets

RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y novnc \
    && mkdir -p /usr/local/share/fineco-novnc \
    && cp -a /usr/share/novnc/core /usr/local/share/fineco-novnc/core \
    && cp -a /usr/share/novnc/vendor /usr/local/share/fineco-novnc/vendor \
    && install -m 0644 /usr/share/doc/novnc/copyright /usr/local/share/fineco-novnc/LICENSE.txt \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

FROM base AS browser-helper-build

RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y gcc libc6-dev \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY lib/fineco/browser_login_runtime/supervisor.c /tmp/fineco-browser-supervisor.c
RUN mkdir -p /out \
    && gcc -std=c11 -O2 -Wall -Wextra -Werror -Wformat=2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
      -o /out/fineco-browser-supervisor /tmp/fineco-browser-supervisor.c \
    && strip /out/fineco-browser-supervisor

# install the isolated browser runtime only into the final application image.
FROM base AS browser

RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y chromium chromium-sandbox xvfb x11vnc util-linux \
    && mkdir -p /etc/chromium/policies/managed /usr/local/libexec \
    && groupadd --system --gid 1001 fineco-browser \
    && useradd --system --uid 1001 --gid 1001 --no-create-home --shell /usr/sbin/nologin fineco-browser \
    && mkdir -p /run/sure-fineco /tmp/.X11-unix \
    && chown root:root /run/sure-fineco /tmp/.X11-unix \
    && chmod 0711 /run/sure-fineco \
    && chmod 1777 /tmp/.X11-unix \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY config/docker/chromium-fineco-policy.json /etc/chromium/policies/managed/sure-fineco.json
RUN chown root:root /etc/chromium/policies/managed/sure-fineco.json \
    && chmod 0444 /etc/chromium/policies/managed/sure-fineco.json

COPY --from=novnc-assets /usr/local/share/fineco-novnc /usr/local/share/fineco-novnc

# Final stage for app image
FROM browser

# run Rails as a non-root user while the browser remains in its separate UID.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chmod 0750 /rails
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
COPY --chown=rails:rails --from=browser /usr/local/share/fineco-novnc /rails/public/fineco-novnc
COPY --from=browser-helper-build --chown=root:1000 --chmod=4750 /out/fineco-browser-supervisor /usr/local/libexec/fineco-browser-supervisor
USER 0:0
RUN chown rails:rails /rails && chmod 0750 /rails
USER 1000:1000

# runtime-only version metadata stays after cached dependency and asset layers.
ARG BUILD_COMMIT_SHA
ENV BUILD_COMMIT_SHA=${BUILD_COMMIT_SHA}

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
