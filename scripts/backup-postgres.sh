#!/usr/bin/env bash
# Backs up a namespace's Postgres database to a local SQL dump.
#
# In production this would run on a schedule (e.g. a Kubernetes CronJob)
# and upload straight to S3 with versioning + lifecycle rules instead of
# writing to local disk - see docs/runbooks/disaster-recovery.md.
#
# Usage: ./scripts/backup-postgres.sh <namespace>
set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/../backups"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_FILE="$BACKUP_DIR/${NAMESPACE}-${TIMESTAMP}.sql"

mkdir -p "$BACKUP_DIR"

echo "==> Backing up postgres in namespace '$NAMESPACE' to $OUTPUT_FILE"
kubectl exec -n "$NAMESPACE" postgres-0 -- pg_dump -U appuser -d appdb --clean --if-exists > "$OUTPUT_FILE"

SIZE="$(du -h "$OUTPUT_FILE" | cut -f1)"
echo "==> Backup complete: $OUTPUT_FILE ($SIZE)"
