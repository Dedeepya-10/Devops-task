# Runbook: Disaster Recovery

## Recovery objectives

| Term | Meaning | Target for this system |
|---|---|---|
| **RPO** (Recovery Point Objective) | How much data can we afford to lose, measured in time | **1 hour** for development/staging, **15 minutes** for production |
| **RTO** (Recovery Time Objective) | How long it should take to be back up and serving traffic after an incident | **30 minutes** for development/staging, **15 minutes** for production |

These targets assume the backup/restore scripts in this repo, run manually
by an on-call engineer. The actual restore operation itself takes seconds
(see the test below) - the RTO budget is dominated by detection and human
response time, not the mechanics of restoring.

**How to hit the RPO target:** run `scripts/backup-postgres.sh` on a
schedule matching the target - hourly for dev/staging, every 15 minutes for
production. In this demo it's run manually; in production this would be a
Kubernetes CronJob (see "Production enhancements" below).

## What is and isn't covered

This covers **data loss in the Postgres database** - accidental deletes,
a bad migration, a corrupted table, or the PersistentVolume itself being
lost. It does not cover total AWS region loss (see "Cluster failover
strategy" below, which is a design document rather than a tested
procedure, since a single-region local demo can't exercise a multi-region
failover).

## Backup procedure

```bash
./scripts/backup-postgres.sh <namespace>
```

This runs `pg_dump` inside the `postgres-0` pod and saves a timestamped
`.sql` file to `backups/` locally. In production, this same command's
output would be piped to `aws s3 cp - s3://<backup-bucket>/<namespace>/$(date ...).sql`
instead of local disk, with S3 versioning and a lifecycle policy to expire
old backups automatically.

## Restore procedure

```bash
./scripts/restore-postgres.sh <namespace> backups/<namespace>-<timestamp>.sql
```

This pipes the dump back into `psql` inside the running `postgres-0` pod.
The dump is generated with `--clean --if-exists`, so it safely drops and
recreates the `items`/`jobs` tables rather than erroring on "already
exists".

## Backup restoration test (actually performed, not simulated)

Ran on 2026-07-29 against the `staging` namespace:

1. **Created real test data** via the API:
   ```
   POST /api/items {"name":"dr-test-item-1"}  -> id 1
   POST /api/items {"name":"dr-test-item-2"}  -> id 2
   ```
   Both were picked up and marked `processed` by the worker, confirmed via
   `GET /api/items`.

2. **Took a backup:**
   ```
   $ ./scripts/backup-postgres.sh staging
   ==> Backing up postgres in namespace 'staging' to backups/staging-20260729T180447Z.sql
   ==> Backup complete: backups/staging-20260729T180447Z.sql (8.0K)
   ```

3. **Simulated a disaster** - deliberately destroyed the data:
   ```
   $ kubectl exec -n staging postgres-0 -- psql -U appuser -d appdb \
       -c "TRUNCATE items, jobs RESTART IDENTITY CASCADE;"
   TRUNCATE TABLE
   ```
   Confirmed the data was actually gone: `GET /api/items` returned `[]`.

4. **Restored from the backup:**
   ```
   $ ./scripts/restore-postgres.sh staging backups/staging-20260729T180447Z.sql
   ==> Restoring backups/staging-20260729T180447Z.sql into namespace 'staging'
   ...
   COPY 2
   COPY 2
   ==> Restore complete
   ```

5. **Verified the exact same data came back** - same IDs, names, statuses,
   and original timestamps, via `GET /api/items`:
   ```json
   [
     {"id":2,"name":"dr-test-item-2","status":"processed","created_at":"2026-07-29T18:03:42.315Z"},
     {"id":1,"name":"dr-test-item-1","status":"processed","created_at":"2026-07-29T18:03:42.289Z"}
   ]
   ```

**Result: pass.** The full cycle (backup -> destroy -> restore -> verify)
took under two minutes end to end for this dataset size, well inside the
30-minute RTO target - though a real production dataset would take
proportionally longer to dump/restore, which is exactly why the RTO target
should be re-validated periodically as data volume grows, not assumed
constant.

## Persistent volume backup strategy

The Postgres data directory lives on a PersistentVolumeClaim
(`postgres-storage`, provisioned via kind's local-path-provisioner in this
demo). Two complementary layers of protection:

1. **Logical backups** (`pg_dump`, above) - portable across Postgres
   versions, human-readable, easy to restore selectively.
2. **Volume snapshots** - in production on EKS, this would be EBS
   snapshots of the underlying volume (via the AWS EBS CSI driver's
   `VolumeSnapshot` support), taken on the same schedule as the logical
   backups. Volume snapshots protect against filesystem-level corruption
   that a logical dump wouldn't catch, and restore faster for large
   datasets since they don't need to replay every `INSERT`.

This demo only implements the logical backup layer - kind's
local-path-provisioner (a `hostPath` under the hood) doesn't support real
snapshotting, and adding a snapshot layer wouldn't test anything
meaningfully different from a second `pg_dump` on a local single-node
cluster.

## Cluster failover strategy (design - not testable locally)

This demo runs a single-node kind cluster with a single Postgres pod - by
definition, there is no failover if this one machine dies, which is a
correct and honest limitation of running locally rather than on EKS.

For a real production deployment, the failover design would be:

- **Compute**: EKS with worker nodes spread across at least 3 Availability
  Zones. A node or even a whole AZ can be lost without taking down the
  cluster - Kubernetes reschedules affected pods onto healthy nodes in
  other AZs automatically.
- **Database**: This is the more important one. A single Postgres pod in
  a StatefulSet - which is what this demo uses - is a single point of
  failure no matter how good the backup script is; restoring from a backup
  after a crash still means real downtime. In production, Postgres should
  run as **Amazon RDS (Multi-AZ)** instead of self-hosted in-cluster:
  RDS handles automatic failover to a synchronously-replicated standby in
  a different AZ, typically within 1-2 minutes, without needing a human to
  run a restore script at all. The application's `PGHOST` would point at
  the RDS endpoint instead of a `postgres` Kubernetes Service - everything
  else about the api/worker deployment stays the same.
- **Cross-region**: out of scope for this task's RTO/RPO targets, but the
  next step up would be cross-region read replicas (RDS supports this) and
  Route 53 health-check-based DNS failover - only worth the added
  complexity and cost if the business's actual availability requirements
  justify surviving a full AWS region outage.

## Production enhancements not implemented here

- Scheduled backups via a Kubernetes `CronJob` running
  `scripts/backup-postgres.sh`'s logic and uploading to S3, instead of a
  manually-run script.
- `velero` for whole-cluster backup/restore (namespaces, RBAC, ConfigMaps,
  not just database contents) - useful for disaster recovery of the
  cluster's *configuration*, complementary to the data-focused backups here.
- Automated, scheduled restore-drill testing (restore last night's backup
  into a scratch namespace and run a smoke test against it, alerting if it
  fails) rather than a manually-triggered test like the one documented above.
