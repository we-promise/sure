#!/bin/sh
# Guard against starting Postgres on a data directory created by another
# major version. Used by the devcontainer; compose.example.yml and
# compose.example.ai.yml carry the same check inline, because self-hosters
# only download the compose file.
#
# Usage: db-version-check.sh <volume-dir> <expected-major>
#
# PostgreSQL 18+ official images keep the cluster in <major>/docker under the
# volume, mounted at /var/lib/postgresql. Earlier versions wrote straight into
# the mounted directory (the volume root, or data/ under it). A cluster in the
# old place is never read by the new image, which would start empty beside
# it, so it always blocks. Only <expected-major>/docker counts as a match;
# other <major>/docker clusters may remain after a pg_upgrade.
set -u

DATA_DIR="${1:?usage: db-version-check.sh <volume-dir> <expected-major>}"
EXPECTED_MAJOR="${2:?usage: db-version-check.sh <volume-dir> <expected-major>}"

legacy=""
if [ -f "${DATA_DIR}/PG_VERSION" ]; then
  legacy=$(cat "${DATA_DIR}/PG_VERSION")
elif [ -f "${DATA_DIR}/data/PG_VERSION" ]; then
  legacy=$(cat "${DATA_DIR}/data/PG_VERSION")
fi

have=""
other=""
for f in "${DATA_DIR}"/*/docker/PG_VERSION; do
  [ -f "$f" ] || continue
  if [ "$(cat "$f")" = "${EXPECTED_MAJOR}" ]; then have=1; else other=$(cat "$f"); fi
done

if [ -z "${legacy}" ] && { [ -n "${have}" ] || [ -z "${other}" ]; }; then
  echo "db-version-check: OK"
  exit 0
fi

cat >&2 <<MSG

======================================================================
ERROR: the database volume holds PostgreSQL ${legacy:-$other} data, but
this setup runs PostgreSQL ${EXPECTED_MAJOR}. Nothing was changed and your
data is safe.

In the devcontainer, the quickest fix is a fresh development database:
  docker volume rm <project>_postgres-data   # see: docker volume ls
then rebuild the container and run bin/setup.

For a self-hosted install, upgrade the data instead (a backup is taken
first), from the folder with your compose file:
  sh sure-backup upgrade-postgres

Details: docs/hosting/docker.md, "PostgreSQL major version upgrades".
======================================================================
MSG
exit 1
