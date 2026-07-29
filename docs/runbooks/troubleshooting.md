# Runbook: Troubleshooting Common Issues

## General diagnostic commands

```bash
kubectl get pods -n <namespace>                          # what's running
kubectl describe pod <pod> -n <namespace>                 # events, scheduling issues
kubectl logs <pod> -n <namespace> [-c <container>]         # application logs
kubectl logs <pod> -n <namespace> --previous                # logs from before a crash/restart
kubectl top pod -n <namespace>                              # live CPU/memory per pod
```

Or in Grafana: the **Logs** panel in each dashboard (via the Loki
datasource) covers the same logs without needing `kubectl` access, and
survives pod restarts (unlike `kubectl logs`, which loses history when a
pod is deleted).

## Pod stuck in `Pending`

Almost always a scheduling constraint. Check:
```bash
kubectl describe pod <pod> -n <namespace>
```
and look at the `Events` section. The two most common causes in this setup:
- **ResourceQuota exhausted** - the namespace's `ResourceQuota` (see
  `terraform/variables.tf`) doesn't have enough remaining `requests.cpu`/
  `requests.memory` for a new pod. Check with
  `kubectl describe resourcequota -n <namespace>`.
- **PVC can't bind** - for `postgres-0` specifically, check
  `kubectl get pvc -n <namespace>` for a `Pending` PersistentVolumeClaim.

## Pod stuck in `CrashLoopBackOff`

```bash
kubectl logs <pod> -n <namespace> --previous
```
This is the single most useful command here - it shows the logs from the
crashed attempt, not the (empty) logs of the container that just
restarted. The `PodCrashLooping` alert (see `monitoring/prometheus/alert-rules.yaml`)
fires automatically after 3 restarts in 15 minutes.

**A real example hit during this build:** the `api` pod logged
`Failed to initialize database schema ... getaddrinfo ENOTFOUND postgres`
on first boot. This wasn't a crash (the process kept running and serving
`/health`), but `/ready` correctly reported `not ready`, and any request
touching the database returned 500. Root cause: Kubernetes gives no
ordering guarantee between a Deployment and a StatefulSet starting at
roughly the same time - the `postgres` Service's DNS wasn't resolvable
yet the instant `api` first tried to connect. Fixed in
`services/api/src/server.js` by retrying the schema init with backoff
instead of trying once and giving up - see the code comment there for the
full reasoning. This is why `/health` and `/ready` are deliberately
different endpoints: a pod can be "alive" but correctly "not ready".

## Pod blocked by Pod Security admission ("would violate PodSecurity...")

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
```
This happened while building the `production` namespace, which enforces
the `restricted` Pod Security Standard (`terraform/main.tf` ->
`kubernetes_namespace.env` labels). The fix was adding an explicit
`securityContext` (pod-level `runAsNonRoot`/`runAsUser`/`seccompProfile`,
container-level `allowPrivilegeEscalation: false` +
`capabilities.drop: ["ALL"]`) to every workload in `k8s/base/*/`, applied
to all three environments uniformly rather than just production - see
those files for the exact blocks. If a *new* workload hits this same
warning, copy the `securityContext` pattern from `k8s/base/api/deployment.yaml`.

## `ExternalSecret` not syncing / `db-credentials` Secret missing

```bash
kubectl get externalsecret -n <namespace>
kubectl describe externalsecret db-credentials -n <namespace>
```
Check the `STATUS`/`READY` columns. Common causes:
- The `ClusterSecretStore` isn't `Valid` - `kubectl get clustersecretstore`
  and check its `STATUS`.
- The `eso-reader` ServiceAccount (in the `secrets-source` namespace)
  lost its RoleBinding - see `secret-management.md`.
- The source Secret name doesn't match `remoteRef.key` in the
  `ExternalSecret` spec (`k8s/secrets/external-secret-<env>.yaml`).

## App pods can't authenticate to Postgres after a secret rotation

If `db-credentials` was just rotated (see `secret-management.md`) but
`api`/`worker` pods are erroring on DB auth: **environment variables set
via `secretKeyRef` are only read once, at pod start** - they don't
auto-update when the underlying Secret changes. A
`kubectl rollout restart deployment/api -n <namespace>` (and same for
`worker`) is required after any credential rotation. Also confirm the
*actual* Postgres user password was updated to match (`ALTER USER ... WITH
PASSWORD ...`) - changing the Secret's value alone does **not** change
Postgres's own stored password, since Postgres only applies
`POSTGRES_PASSWORD` at first database initialization, not on every
restart. This exact scenario is what `secret-management.md`'s rotation
procedure walks through.

## Deployment stuck / rollout never completes

```bash
kubectl rollout status deployment/<name> -n <namespace> --timeout=30s
```
If this times out, `scripts/deploy.sh` already auto-triggers a
`kubectl rollout undo` - check `kubectl rollout history deployment/<name> -n <namespace>`
to see the revision history and confirm which version is actually live.

## Prometheus alert firing - what to check per alert

See `monitoring/prometheus/alert-rules.yaml` for the exact expressions.
Quick reference:

| Alert | First thing to check |
|---|---|
| `HighCPUUsage` / `HighMemoryUsage` | `kubectl top pod -n <namespace>`; is this real load or a leak? |
| `CriticalMemoryUsage` | Pod is about to be OOMKilled - check for a memory leak or raise the limit |
| `PodCrashLooping` | `kubectl logs --previous` (see above) |
| `PodNotReady` | `kubectl describe pod` - readiness probe failing? |
| `PostgresDown` | `kubectl get pods -n <namespace> -l app=postgres`; check PVC and node health |
| `DeploymentReplicasMismatch` | `kubectl rollout status` - stuck rollout, or quota blocking new pods |
| `HPAMaxedOut` | See `scaling.md` |
| `HighAPIErrorRate` | Check `api` pod logs for the actual 5xx cause |
| `WorkerStalled` | `kubectl logs deployment/worker` - is the poll loop actually running? |
| `HighJobFailureRate` | Check `worker` logs for the specific job failure reason |
| `ResourceQuotaNearlyExhausted` | See `scaling.md` (vertical) and `cost-analysis.md` |
| `PersistentVolumeNearlyFull` | See `disaster-recovery.md` for backup, then expand the PVC |

## Grafana/Prometheus/Loki themselves not working

```bash
kubectl get pods -n monitoring
```
All of Prometheus, Grafana, Alertmanager, and Loki should show `Running`.
If Grafana shows no data at all (not just missing panels), check its
datasources: Settings -> Data Sources in the Grafana UI, or
`kubectl get configmap loki-datasource -n monitoring` /
`kubectl exec` into Prometheus to confirm `up{}` targets are healthy.
