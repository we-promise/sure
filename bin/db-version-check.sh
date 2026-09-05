#!/bin/sh
# Guard against starting Postgres on a data directory created by an
# incompatible major version. Without this, the postgres container just
# crash-loops on FATAL: database files are incompatible with server.
#
# Usage: db-version-check.sh <data-dir> <expected-major>
# A data dir with no PG_VERSION file (fresh install) passes.
#
# PostgreSQL 18+ official images keep the cluster in a version-specific
# subdirectory of the volume (/var/lib/postgresql/<major>/docker), while
# PostgreSQL 16 and earlier wrote directly into the mounted directory
# (/var/lib/postgresql/data). A volume can hold several clusters after a
# pg_upgrade (e.g. 16/docker AND 18/docker), so the expected major's
# cluster wins when present - that is the one the server will use.
set -u

DATA_DIR="${1:?usage: db-version-check.sh <data-dir> <expected-major>}"
EXPECTED_MAJOR="${2:?usage: db-version-check.sh <data-dir> <expected-major>}"

VERSION_FILE=""

# 1. The cluster the server will actually use: <expected-major>/docker.
if [ -f "${DATA_DIR}/${EXPECTED_MAJOR}/docker/PG_VERSION" ]; then
  VERSION_FILE="${DATA_DIR}/${EXPECTED_MAJOR}/docker/PG_VERSION"
else
  # 2. Any other layout: other versioned dirs, legacy data/, direct mount.
  for candidate in \
    "${DATA_DIR}"/*/docker/PG_VERSION \
    "${DATA_DIR}/data/PG_VERSION" \
    "${DATA_DIR}/PG_VERSION"
  do
    if [ -f "${candidate}" ]; then
      VERSION_FILE="${candidate}"
      break
    fi
  done
fi

if [ -z "${VERSION_FILE}" ]; then
  echo "db-version-check: no PG_VERSION under ${DATA_DIR} (fresh install) - OK"
  exit 0
fi

ACTUAL_MAJOR="$(cat "${VERSION_FILE}")"
if [ "${ACTUAL_MAJOR}" = "${EXPECTED_MAJOR}" ]; then
  echo "db-version-check: data directory is PostgreSQL ${ACTUAL_MAJOR} (${VERSION_FILE}), matches the image - OK"
  exit 0
fi

cat >&2 <<MSG

======================================================================
ERROR: PostgreSQL major version mismatch

The database data directory was created by PostgreSQL ${ACTUAL_MAJOR}
(found: ${VERSION_FILE}), but this setup now runs PostgreSQL
${EXPECTED_MAJOR}. PostgreSQL ${EXPECTED_MAJOR} cannot read
${ACTUAL_MAJOR} data files, so the database container would crash-loop
or silently start an empty database. Startup has been stopped on
purpose.

To KEEP your data, migrate it first with one of:
  * pg_dump from the old version, pg_restore into the new one, or
  * pg_upgrade (fast, in-place).
See docs/hosting/docker.md for details.

To start over with an EMPTY database (destroys existing data):
  docker compose down
  docker volume rm <project>_postgres-data
  docker compose up
======================================================================
MSG
exit 1
