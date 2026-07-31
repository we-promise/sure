#!/bin/sh
set -e

# Configuration
BACKUP_OVERWRITE=${BACKUP_OVERWRITE:-false}
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

trap 'rm -f "${TEMP_FILE}"' EXIT

echo "Starting backup for ${POSTGRES_DB} to ${TEMP_FILE}..."
set -o pipefail
PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${TEMP_FILE}"
set +o pipefail

echo "Uploading ${TEMP_FILE} to ${BACKUP_DESTINATION}/${FILENAME} via rclone..."
rclone copy "${TEMP_FILE}" "${BACKUP_DESTINATION}"

echo "Cleaning up..."
rm "${TEMP_FILE}"

echo "Backup complete!"
