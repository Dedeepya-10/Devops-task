# Architecture

## Overall system

```mermaid
graph TB
    subgraph "GitHub"
        Repo[Devops-task repo]
        Actions[GitHub Actions workflow]
        GHCR[GHCR - container images]
    end

    subgraph "Self-hosted runner (this machine)"
        Runner[Runner process]
    end

    subgraph "kind cluster: advanced-devops"
        subgraph "Namespace: development"
            DevAPI[api x1]
            DevWorker[worker x1]
            DevPG[(postgres)]
        end
        subgraph "Namespace: staging"
            StgAPI[api x2]
            StgWorker[worker x1]
            StgPG[(postgres)]
        end
        subgraph "Namespace: production"
            ProdAPI[api x3-10 HPA]
            ProdWorker[worker x2-6 HPA]
            ProdPG[(postgres)]
        end
        subgraph "Namespace: monitoring"
            Prom[Prometheus]
            Graf[Grafana]
            Loki[Loki + Promtail]
            AM[Alertmanager]
        end
        subgraph "Namespace: secrets-source"
            SecSrc[(Secret store\nstands in for AWS Secrets Manager)]
        end
        subgraph "Namespace: external-secrets"
            ESO[External Secrets Operator]
        end
    end

    Repo -->|push to main| Actions
    Actions -->|runs on| Runner
    Runner -->|build, scan, push| GHCR
    Runner -->|kind load + kubectl apply -k| DevAPI
    Runner -->|kind load + kubectl apply -k| StgAPI
    Runner -->|kind load + kubectl apply -k, needs approval| ProdAPI

    DevAPI --> DevPG
    DevWorker --> DevPG
    StgAPI --> StgPG
    StgWorker --> StgPG
    ProdAPI --> ProdPG
    ProdWorker --> ProdPG

    ESO -->|reads| SecSrc
    ESO -->|syncs db-credentials into| DevAPI
    ESO -->|syncs db-credentials into| StgAPI
    ESO -->|syncs db-credentials into| ProdAPI

    Prom -->|scrapes /metrics| DevAPI
    Prom -->|scrapes /metrics| StgAPI
    Prom -->|scrapes /metrics| ProdAPI
    Prom -->|scrapes /metrics| DevWorker
    Prom -->|scrapes /metrics| StgWorker
    Prom -->|scrapes /metrics| ProdWorker
    Graf -->|queries| Prom
    Graf -->|queries| Loki
    Prom -->|alerts| AM
```

## Why one cluster, three namespaces (not three clusters)

The task allows either. Three namespaces inside one cluster was chosen
over three separate clusters for cost (see `cost-analysis.md` - a second
and third EKS control plane alone would add ~$146/month with zero
functional benefit at this scale) and operational simplicity (one set of
monitoring/logging infrastructure instead of three, one place to look for
cluster-level problems). The isolation that three separate clusters would
buy - namespace A can never accidentally see namespace B's resources at
the API level - is instead provided by `NetworkPolicy` (default-deny +
explicit allows), `ResourceQuota`, `LimitRange`, and per-namespace RBAC
`Role`s, all defined in `terraform/main.tf`. The tradeoff: a
cluster-level failure (e.g., the control plane itself) affects all three
environments at once, which three separate clusters would avoid. At this
scale, that tradeoff favors one cluster; it's explicitly called out here
because it wouldn't necessarily hold at a much larger scale (see
`cost-analysis.md`'s "Recommendations for future scaling").

## Networking

```mermaid
graph LR
    subgraph "development namespace"
        direction TB
        D_NP["NetworkPolicy:\ndefault-deny-ingress"]
        D_API[api]
        D_Worker[worker]
        D_PG[(postgres)]
        D_API <-->|"5432 (allowed:\nsame-namespace)"| D_PG
        D_Worker <-->|5432| D_PG
    end

    subgraph "monitoring namespace"
        M_Prom[Prometheus]
    end

    M_Prom -.->|"scrape :4000/:4100\n(allowed: allow-monitoring-scrape)"| D_API
    M_Prom -.->|scrape| D_Worker

    Internet((Internet)) -.->|"BLOCKED\n(no ingress rule\nfor 0.0.0.0/0)"| D_API

    style Internet fill:#f66,color:#fff
```

Every namespace gets the same three `NetworkPolicy` objects (identical
logic, different namespace - see `terraform/main.tf`):

1. **`default-deny-ingress`** - an empty `podSelector` with `policyTypes:
   [Ingress]` and no `ingress` rules at all, which blocks all inbound
   traffic to every pod in the namespace by default. Kubernetes
   NetworkPolicies are additive/allow-based once any policy exists for a
   pod, so this is the deny-by-default baseline everything else layers on
   top of.
2. **`allow-same-namespace`** - allows ingress from any pod whose
   namespace carries the matching `environment` label. This is what lets
   `api`/`worker` reach `postgres` within the same environment.
3. **`allow-monitoring-scrape`** - allows ingress from the `monitoring`
   namespace specifically, so Prometheus can reach every pod's `/metrics`
   endpoint despite the default-deny.

Nothing outside the cluster (and nothing in a *different* environment's
namespace) can reach an application pod directly - the only path in is
through whichever Service the pod belongs to, and even that is gated by
the same NetworkPolicy rules.

## CI/CD flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub
    participant Runner as Self-hosted runner
    participant K8s as kind cluster

    Dev->>GH: git push main
    GH->>Runner: trigger workflow

    Note over Runner: test job (matrix: api, worker)
    Runner->>Runner: npm ci, lint, test

    Note over Runner: build-and-scan job (matrix: api, worker)
    Runner->>Runner: docker build
    Runner->>Runner: Trivy scan (report-only)
    Runner->>GH: docker push to GHCR
    Runner->>K8s: kind load docker-image

    Note over Runner,K8s: deploy-development job
    Runner->>K8s: kustomize set image + kubectl apply -k
    Runner->>K8s: kubectl rollout status
    alt rollout fails
        Runner->>K8s: kubectl rollout undo (automatic)
        Runner->>GH: job fails, pipeline stops here
    else rollout succeeds
        Runner->>K8s: health check (exec curl /health)
    end

    Note over Runner,K8s: deploy-staging job (same pattern)
    Note over GH: deploy-production job WAITS for<br/>required reviewer approval
    Dev->>GH: approve production deployment
    Runner->>K8s: deploy to production (same pattern)
    Runner->>GH: write deployment summary to $GITHUB_STEP_SUMMARY
```

## Disaster recovery flow

```mermaid
graph TB
    A[Scheduled/manual trigger] --> B["scripts/backup-postgres.sh env"]
    B --> C["pg_dump inside postgres-0 pod"]
    C --> D["backups/env-timestamp.sql"]
    D -.->|production: would upload to| E[S3 with versioning]

    F[Incident: data loss detected] --> G{Backup available?}
    G -->|yes| H["scripts/restore-postgres.sh env backup-file"]
    G -->|no data loss, pod/node failure only| I["Kubernetes reschedules the pod;\nPVC data survives pod restarts"]
    H --> J["psql restores into postgres-0"]
    J --> K["Verify: query the app / GET /api/items"]
    K --> L["RTO/RPO met? See disaster-recovery.md"]

    style F fill:#f66,color:#fff
```

See `docs/runbooks/disaster-recovery.md` for the RTO/RPO targets and an
actual, real (not simulated-in-prose) test of this exact flow.

## Component summary

| Component | What it is | Where |
|---|---|---|
| `api` | Node.js/Express service - the "API service" | `services/api/` |
| `worker` | Node.js background job processor - the "worker" service | `services/worker/` |
| `postgres` | The "database service" - official `postgres:16-alpine` image | `k8s/base/postgres/` |
| Kubernetes cluster | `kind` (local), 1 node | `terraform/kind-config.yaml` |
| Namespaces + quotas + RBAC + NetworkPolicies | Terraform-managed | `terraform/main.tf` |
| Application manifests | Kustomize (base + 3 overlays) | `k8s/` |
| Monitoring | Prometheus + Grafana + Alertmanager (`kube-prometheus-stack`) | Helm release, `monitoring/prometheus/` |
| Logging | Loki + Promtail (`loki-stack`) | Helm release, `monitoring/loki/` |
| Secret management | External Secrets Operator + `secrets-source` namespace | `terraform/main.tf`, `k8s/secrets/` |
| CI/CD | GitHub Actions + self-hosted runner | `.github/workflows/deploy.yml` |
| Backups | `pg_dump`/`psql` scripts | `scripts/backup-postgres.sh`, `scripts/restore-postgres.sh` |
