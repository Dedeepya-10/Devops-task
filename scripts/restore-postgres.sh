#!/usr/bin/env bash
# Restores a namespace's Postgres database from a SQL dump produced by
# backup-postgres.sh.
#
# Usage: ./scripts/restore-postgres.sh <namespace> <path-to-backup.sql>
set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <path-to-backup.sql>}"
BACKUP_FILE="${2:?Usage: $0 <namespace> <path-to-backup.sql>}"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

echo "==> Restoring $BACKUP_FILE into namespace '$NAMESPACE'"
kubectl exec -i -n "$NAMESPACE" postgres-0 -- psql -U appuser -d appdb < "$BACKUP_FILE"

echo "==> Restore complete"
