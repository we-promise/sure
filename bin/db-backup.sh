#!/bin/sh
# Deprecated: replaced by bin/sure-backup, which backs up the database, uploaded
# files and config together. Kept so older compose files fail with a clear hint.
if [ -x /usr/local/bin/sure-backup ]; then
  exec /usr/local/bin/sure-backup scheduled
fi
echo "[db-backup] ERROR: db-backup.sh was replaced by bin/sure-backup." >&2
echo "[db-backup] Update the backup service from compose.example.yml; see docs/hosting/docker.md." >&2
exit 1
