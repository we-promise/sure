#!/bin/sh
set -e

# Configuration
BACKUP_OVERWRITE=${BACKUP_OVERWRITE:-false}
BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS:-7}
BACKUP_DESTINATION=${BACKUP_DESTINATION}

if [ -z "$BACKUP_DESTINATION" ]; then
  echo "Error: BACKUP_DESTINATION is not set."
  exit 1
fi

if [ -z "$POSTGRES_DB" ] || [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$POSTGRES_HOST" ]; then
  echo "Error: Database connection variables are not fully set."
  exit 1
fi

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

if [ "$BACKUP_OVERWRITE" = "true" ]; then
  FILENAME="backup_latest.sql.gz"
else
  FILENAME="backup_${TIMESTAMP}.sql.gz"
fi

TEMP_FILE="/tmp/${FILENAME}"
PGPASS_FILE="/tmp/.pgpass"

trap 'rm -f "${TEMP_FILE}" "${PGPASS_FILE}"' EXIT

# Securely provide the database password via .pgpass
echo "${POSTGRES_HOST}:5432:${POSTGRES_DB}:${POSTGRES_USER}:${POSTGRES_PASSWORD}" > "${PGPASS_FILE}"
chmod 0600 "${PGPASS_FILE}"
export PGPASSFILE="${PGPASS_FILE}"

echo "Starting backup for ${POSTGRES_DB} to ${TEMP_FILE}..."
set -o pipefail
pg_dump -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${TEMP_FILE}"
set +o pipefail

DEST_PATH="${BACKUP_DESTINATION}/${POSTGRES_DB}"
echo "Uploading ${TEMP_FILE} to ${DEST_PATH}/${FILENAME} via rclone..."
rclone copy "${TEMP_FILE}" "${DEST_PATH}"

if [ "$BACKUP_OVERWRITE" != "true" ] && [ -n "$BACKUP_KEEP_DAYS" ]; then
  if ! [ "$BACKUP_KEEP_DAYS" -gt 0 ] 2>/dev/null; then
    echo "Error: BACKUP_KEEP_DAYS must be a positive integer (got: ${BACKUP_KEEP_DAYS})."
    exit 1
  fi
  echo "Pruning remote backups older than ${BACKUP_KEEP_DAYS} days..."
  rclone delete "${DEST_PATH}" --min-age "${BACKUP_KEEP_DAYS}d" --include "backup_*.sql.gz"
fi

echo "Cleaning up..."
rm -f "${TEMP_FILE}" "${PGPASS_FILE}"

echo "Backup complete!"
