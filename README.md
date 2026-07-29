# Advanced DevOps Challenge — Production-Ready Multi-Environment Deployment

A 3-service microservices app (api, worker, Postgres) deployed across
three isolated Kubernetes namespaces (development/staging/production),
with full monitoring/logging, RBAC, network policies, external secret
management, automated CI/CD (test → build → scan → deploy → rollback),
and disaster recovery — built and tested end to end on a local `kind`
cluster.

See `docs/decision-log.md` for the reasoning behind every major choice
below, and `docs/architecture.md` for diagrams.

## Repository layout

```
.
├── services/
│   ├── api/                    # Express API service (+ Jest tests, Dockerfile)
│   └── worker/                  # Background job processor (+ Jest tests, Dockerfile)
├── k8s/
│   ├── base/                    # Kustomize base: api, worker, postgres manifests
│   ├── overlays/                 # development / staging / production overlays
│   └── secrets/                  # ClusterSecretStore + ExternalSecret CRs
├── terraform/                    # Cluster, namespaces, RBAC, quotas, network
│   │                              policies, monitoring stack (all via Terraform)
│   └── kind-config.yaml
├── monitoring/
│   ├── prometheus/                # Helm values, 12 alert rules
│   ├── grafana/dashboards/         # 5 custom dashboards
│   └── loki/                       # Helm values
├── scripts/
│   ├── deploy.sh                   # Used by CI/CD; rollout + auto-rollback
│   ├── backup-postgres.sh
│   └── restore-postgres.sh
├── .github/workflows/deploy.yml    # test -> build/scan/push -> deploy x3 -> approval gate
└── docs/
    ├── architecture.md              # Mermaid diagrams
    ├── decision-log.md
    ├── cost-analysis.md
    └── runbooks/
        ├── deployment.md
        ├── scaling.md
        ├── troubleshooting.md
        ├── on-call.md
        └── secret-management.md
```

## Prerequisites

- Docker
- `kubectl`, `kind`, `helm`, `kustomize`
- Terraform >= 1.5
- Node.js 20 (for running tests locally outside Docker)

## Setting this up from scratch

```bash
# 1. Stand up the cluster + all infrastructure (namespaces, RBAC, quotas,
#    network policies, monitoring stack, External Secrets Operator)
cd terraform
terraform init
terraform apply -target=null_resource.kind_cluster -auto-approve   # phase 1: cluster must exist before the k8s/helm providers can connect
terraform apply -auto-approve                                       # phase 2: everything else

# 2. Apply the CRD instances that depend on operators from step 1
kubectl apply -f ../monitoring/prometheus/alert-rules.yaml
kubectl apply -f ../k8s/secrets/

# 3. Build the app images and load them into kind
cd ../services/api && docker build -t advanced-api:local . && cd ../worker && docker build -t advanced-worker:local .
kind load docker-image advanced-api:local advanced-worker:local --name advanced-devops

# 4. Deploy to all three environments
cd ../../k8s
kubectl apply -k overlays/development
kubectl apply -k overlays/staging
kubectl apply -k overlays/production

# 5. Reconcile the Postgres password with the ExternalSecrets-managed
#    secret (needed once, since Postgres only applies POSTGRES_PASSWORD
#    at first initialization - see docs/runbooks/secret-management.md)
for ns in development staging production; do
  PW=$(kubectl get secret db-credentials -n $ns -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
  kubectl exec -n $ns postgres-0 -- psql -U appuser -d appdb -c "ALTER USER appuser WITH PASSWORD '$PW';"
done
```

## Verifying it worked

```bash
kubectl get pods -A
kubectl port-forward -n development svc/api 4000:80
curl localhost:4000/          # {"message":"API service is running",...}
curl localhost:4000/health    # {"status":"ok"}
curl localhost:4000/ready     # {"status":"ready"}  <- checks DB connectivity
```

Grafana: `http://localhost:30300` (NodePort, mapped by `terraform/kind-config.yaml`)
— login `admin` / the password in `terraform.tfvars`' `grafana_admin_password`
(defaults to `admin-demo-password`).

Prometheus: `http://localhost:30090`

## CI/CD

`.github/workflows/deploy.yml` runs on every push to `main`:

```
test (api, worker)  ->  build-and-scan (Trivy)  ->  deploy-development
                                                  -> deploy-staging
                                                  -> deploy-production (requires manual approval)
```

This needs a **self-hosted runner** registered on the same machine running
the kind cluster (a GitHub-hosted runner has no network path to a
cluster that only exists inside this machine's Docker daemon) - see
`docs/runbooks/deployment.md` for the full explanation and
`docs/decision-log.md` #6.

To set up the runner on a fresh machine:
1. Settings → Actions → Runners → New self-hosted runner on this repo,
   copy the registration token
2. `./config.sh --url <repo-url> --token <token> --labels self-hosted,kind-local`
3. `./run.sh` (or install as a service with `sudo ./svc.sh install`)

To require manual approval before production deploys: Settings →
Environments → `production` → add required reviewers.

## Environment differences

| | Development | Staging | Production |
|---|---|---|---|
| `api` replicas | 1 (fixed) | 2 (fixed) | 3-10 (HPA, 70% CPU / 80% mem) |
| `worker` replicas | 1 (fixed) | 1 (fixed) | 2-6 (HPA, 70% CPU) |
| `api`/`worker` resources | 25-150m CPU / 32-96Mi | 50-250m CPU / 64-128Mi | 75-400m CPU / 96-192Mi |
| Postgres resources | default (100m/128Mi req) | default | 200m/256Mi req, 5Gi storage |
| Pod Security Standard | `baseline` | `baseline` | `restricted` |
| `LOG_LEVEL` | `debug` | `info` | `warn` |
| ResourceQuota (CPU req/limit) | 1/2 | 2/4 | 4/8 |
| Deployment strategy | rolling (default) | rolling (default) | blue-green cutover (`maxSurge:100%`, `maxUnavailable:0`) |

Full values in `terraform/variables.tf` (namespace-level: quotas, pod
security) and each `k8s/overlays/<env>/kustomization.yaml` (workload-level:
replicas, resources, config).

## Monitoring & observability

- **5 Grafana dashboards** (`monitoring/grafana/dashboards/`): API Service
  Overview, Worker Service Overview, Database Overview, Namespace Resource
  Quotas, Autoscaling (Production HPA)
- **12 Prometheus alert rules** (`monitoring/prometheus/alert-rules.yaml`):
  CPU/memory pressure, pod crashes/not-ready, Postgres down, deployment
  replica mismatches, HPA maxed out, API error rate, worker stalled/job
  failures, resource quota exhaustion, PV nearly full
- **Loki** for centralized logs across all namespaces (via Promtail
  DaemonSet), queryable from the same Grafana instance
- See `docs/runbooks/on-call.md` for what to do when something fires

## Security

- **RBAC**: least-privilege, asymmetric per environment — see
  `docs/decision-log.md` and `terraform/main.tf` (`developer` in dev can
  read+write; `viewer` in staging is read-only; production has **no**
  human-usable ServiceAccount at all, only the CI/CD pipeline's)
- **Network policies**: default-deny ingress + explicit allows (same
  namespace, monitoring scrape) — see `docs/architecture.md`
- **Pod Security Standards**: `restricted` in production, `baseline`
  elsewhere, enforced via namespace labels
- **External Secrets Operator**: real, working, tested credential
  rotation — see `docs/runbooks/secret-management.md`
- **Image scanning**: Trivy on every build — see `docs/decision-log.md` #11

Real screenshots (dashboards, Prometheus targets/alerts, GitHub production
approval gate) are in `docs/monitoring-evidence.md`, alongside real
`kubectl` cluster-state output in `docs/cluster-state-evidence.md`.

## Disaster recovery

RTO/RPO targets, a real (not simulated) backup-destroy-restore test, and
the production failover design (RDS Multi-AZ, multi-AZ EKS nodes) are all
in `docs/runbooks/disaster-recovery.md`.

## Cost analysis

`docs/cost-analysis.md` — actual cost is $0 (runs locally), with a full
projected AWS EKS cost breakdown (~$313/month for this architecture) and
5 concrete cost optimization strategies.

## Challenges encountered (see docs/decision-log.md and runbooks for detail)

- **API/Postgres startup race** — no ordering guarantee between a
  Deployment and StatefulSet starting simultaneously; fixed with retry
  logic, not just a longer `initialDelaySeconds`
- **Pod Security `restricted` blocking production pods** — needed real
  `securityContext` blocks (`runAsNonRoot`, `seccompProfile`,
  `capabilities.drop`), not just documentation
- **8GB RAM budget** — required trimming `kube-prometheus-stack`/Loki
  Helm values significantly, using a single-node kind cluster, and
  choosing Loki over full ELK
- **Credential rotation on a stateful database** — rotating the
  `ExternalSecret`-managed password doesn't change Postgres's actual
  stored password; required an explicit `ALTER USER`, documented as a
  real rotation runbook, not glossed over
- **GHCR vs ECR, self-hosted runner, native vs cross-platform builds** —
  each a deliberate choice given kind + local-machine constraints, not
  defaults copied from Round 1/2 — see `docs/decision-log.md`

## What I'd add with more time

- Real Alertmanager routing to Slack/PagerDuty (currently alerts are
  visible in Prometheus/Alertmanager's own UI, not pushed anywhere)
- `postgres_exporter` for query-level database metrics, instead of only
  container-level CPU/memory/restarts
- Scheduled (CronJob) backups instead of manually-triggered
- Velero for whole-cluster config backup, complementing the
  data-focused Postgres backups here
