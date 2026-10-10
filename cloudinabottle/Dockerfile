# syntax=docker/dockerfile:1

# Cloud in a Bottle all-in-one image for Sure.
#
# Cloud in a Bottle runs each app as one HTTP-reachable container with one
# persistent data directory. This image layers PostgreSQL, Redis and
# supervisord onto the official Sure release image so the whole stack
# (Rails web + Sidekiq worker + PostgreSQL + Redis) runs in that one
# container, with all state under BOTTLE_APP_DATA_DIR.
#
# SURE_IMAGE selects the Sure release to package. Override at build time to
# package a different tag, e.g.:
#   --build-arg SURE_IMAGE=ghcr.io/we-promise/sure:latest
# To package the exact source in this repo instead of a release image, build
# the repo-root Dockerfile first and pass that image here.
ARG SURE_IMAGE=ghcr.io/we-promise/sure:stable
FROM ${SURE_IMAGE}

USER root

# PostgreSQL 16 (same major as compose.example.yml) from the PGDG apt repo,
# plus pgvector (optional document-search vector store), Redis and
# supervisord. The base image already ships curl + ca-certificates. The
# distro codename comes from /etc/os-release so this works whether the base
# image is on bookworm or trixie.
RUN install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && . /etc/os-release \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update -qq \
    && apt-get install --no-install-recommends -y \
         postgresql-16 postgresql-16-pgvector redis-server supervisor \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY cloudinabottle/ /opt/cloudinabottle/
RUN chmod +x /opt/cloudinabottle/*.sh

# Replaces the base image's entrypoint; the wrappers still call
# bin/docker-entrypoint per process so jemalloc and db:prepare behavior
# matches the stock self-hosted image.
ENTRYPOINT ["/opt/cloudinabottle/entrypoint.sh"]
