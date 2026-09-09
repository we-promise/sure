#!/bin/sh
set -e

# shellcheck disable=SC3040
if (set -o pipefail 2>/dev/null); then
  set -o pipefail
fi

# Configuration
BACKUP_OVERWRITE=${BACKUP_OVERWRITE:-false}
BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS:-7}
BACKUP_DESTINATION=${BACKUP_DESTINATION:-}
INSTANCE_ID=${INSTANCE_ID:-default}
POSTGRES_PORT=${POSTGRES_PORT:-5432}

if [ -z "$BACKUP_DESTINATION" ]; then
  echo "Error: BACKUP_DESTINATION is not set."
  exit 1
fi

if [ -z "$POSTGRES_DB" ] || [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$POSTGRES_HOST" ]; then
  echo "Error: Database connection variables are not fully set."
  exit 1
fi

case "${POSTGRES_HOST}${POSTGRES_PORT}${POSTGRES_DB}${POSTGRES_USER}${POSTGRES_PASSWORD}" in
  *"
"*)
    echo "Error: Database connection parameters must not contain newlines."
    exit 1
    ;;
esac

if [ "$BACKUP_OVERWRITE" != "true" ] && [ -n "$BACKUP_KEEP_DAYS" ]; then
  if ! [ "$BACKUP_KEEP_DAYS" -gt 0 ] 2>/dev/null; then
    echo "Error: BACKUP_KEEP_DAYS must be a positive integer (got: ${BACKUP_KEEP_DAYS})."
    exit 1
  fi
fi

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

if [ "$BACKUP_OVERWRITE" = "true" ]; then
  FILENAME="backup_latest.sql.gz"
else
  FILENAME="backup_${TIMESTAMP}_$$.sql.gz"
fi

TMP_DIR=$(umask 077 && mktemp -d)
TEMP_FILE="${TMP_DIR}/${FILENAME}"
PGPASS_FILE="${TMP_DIR}/.pgpass"

# POSIX trap handler to guarantee cleanup of temporary workspace on exit or termination signal
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

# Securely generate .pgpass file with strict permissions (0600) and escaped fields
PG_HOST_ESC=$(printf '%s' "${POSTGRES_HOST}" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')
PG_PORT_ESC=$(printf '%s' "${POSTGRES_PORT}" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')
PG_DB_ESC=$(printf '%s' "${POSTGRES_DB}" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')
PG_USER_ESC=$(printf '%s' "${POSTGRES_USER}" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')
PG_PASS_ESC=$(printf '%s' "${POSTGRES_PASSWORD}" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')

(umask 077 && printf '%s:%s:%s:%s:%s\n' "${PG_HOST_ESC}" "${PG_PORT_ESC}" "${PG_DB_ESC}" "${PG_USER_ESC}" "${PG_PASS_ESC}" > "${PGPASS_FILE}")
chmod 0600 "${PGPASS_FILE}"
export PGPASSFILE="${PGPASS_FILE}"

# Create temp output file with restricted permissions before pg_dump execution
(umask 077 && touch "${TEMP_FILE}")
chmod 0600 "${TEMP_FILE}"

echo "Starting backup for ${POSTGRES_DB} to ${TEMP_FILE}..."
pg_dump -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "${TEMP_FILE}"

DEST_PATH="${BACKUP_DESTINATION%/}/${INSTANCE_ID}"
echo "Uploading ${TEMP_FILE} to ${DEST_PATH}/${FILENAME} via rclone..."
rclone copy "${TEMP_FILE}" "${DEST_PATH}"

if [ "$BACKUP_OVERWRITE" != "true" ] && [ -n "$BACKUP_KEEP_DAYS" ]; then
  echo "Pruning remote backups older than ${BACKUP_KEEP_DAYS} days in ${DEST_PATH}..."
  rclone delete "${DEST_PATH}" --min-age "${BACKUP_KEEP_DAYS}d" --include "backup_*.sql.gz"
fi

echo "Cleaning up..."
rm -rf "${TMP_DIR}"

echo "Backup complete!"
