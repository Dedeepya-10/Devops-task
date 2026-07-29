# Technical Decision Log

Key architectural choices, and the reasoning behind each - written as they
were made, not reconstructed afterward.

## 1. `kind` instead of real AWS EKS

**Decision:** Run a local `kind` (Kubernetes-in-Docker) cluster rather than
provisioning a real EKS cluster.

**Why:** The task explicitly allows this ("minikube, kind, or local Docker
Desktop Kubernetes"). Real EKS costs money continuously just for the
control plane (~$0.10/hr) before any worker nodes, plus load balancers,
NAT gateways, etc. - meaningful for a 48-hour take-home task with no
production traffic to justify it. `kind` also iterates far faster
(cluster up/down in under a minute vs. 15-20+ minutes for EKS), which
mattered given the scope of everything else in this task. Every piece of
Terraform, Kubernetes manifests, and CI/CD in this repo is written to be
directly portable to EKS - see `docs/architecture.md` and
`docs/cost-analysis.md` for exactly what would change (mainly: the cluster
resource itself, and the container registry/image architecture, per
decision #2 below).

## 2. Single-node kind cluster (not 3 nodes)

**Decision:** Started with a 3-node kind config, switched to single-node
before ever deploying anything to it.

**Why:** This runs on an 8GB-RAM laptop, with Docker/kind given a 5GB/4-CPU
budget. Each kind node is a full kubelet+containerd running inside a
Docker container - multiplying that by 3 nodes for no functional benefit
(namespaces, RBAC, HPA, and the monitoring stack all work identically on
one node) would have eaten into the budget needed for
Prometheus+Grafana+Loki+ESO+3 environments' worth of workloads. A real EKS
deployment would use multiple nodes across availability zones - see the
"Cluster failover strategy" section of `docs/runbooks/disaster-recovery.md`.

## 3. One cluster with three namespaces, not three clusters

**Decision:** `development`/`staging`/`production` are namespaces in one
cluster, not three separate clusters.

**Why:** Covered in depth in `docs/architecture.md` - the short version is
cost (a second and third EKS control plane would be pure overhead at this
scale) and operational simplicity (one monitoring stack instead of three),
with isolation provided by NetworkPolicy/RBAC/ResourceQuota instead of
physical cluster separation. Explicitly documented as a scale-dependent
tradeoff, not a universal rule.

## 4. Kustomize (base + overlays) instead of Helm for the application

**Decision:** The api/worker/postgres manifests use plain Kustomize, while
the *infrastructure* (monitoring stack, External Secrets Operator,
metrics-server) uses Helm.

**Why:** Kustomize's base+overlay model maps directly onto "one set of
manifests, three environments with different replica counts/resources/
config" - exactly this task's Part 1 requirement - without needing to
template every value through Helm's `{{ }}` syntax for an application this
size. Helm makes more sense for the monitoring stack and ESO specifically
*because* those are third-party charts already packaged that way upstream
- writing raw manifests for kube-prometheus-stack from scratch would mean
reinventing a large, well-maintained chart for no benefit. This is a
deliberate "right tool for each layer" split, not an accident of not
picking one approach consistently.

## 5. Terraform owns infrastructure + Helm releases; kubectl/Kustomize owns application workloads and CRD instances

**Decision:** `terraform apply` creates the cluster, namespaces, RBAC,
quotas, network policies, and installs Helm charts (Prometheus, Loki, ESO,
metrics-server). `kubectl apply -k` / `kubectl apply -f` handles the
application Deployments/Services and CRD instances (`PrometheusRule`,
`ClusterSecretStore`, `ExternalSecret`).

**Why:** Terraform's `kubernetes_manifest` resource for arbitrary CRDs is
known to be less reliable than Terraform's first-class resource types
(it needs the CRD to already exist at plan time, which creates ordering
headaches for anything installed via a Helm release in the same apply).
Rather than fight that, CRD *instances* that depend on operators
Terraform just installed are applied as a clearly-separated follow-up
step. This mirrors how most real teams actually operate: Terraform for
account/cluster-level infrastructure that changes rarely, GitOps-style
`kubectl`/CI for application-level objects that change on every deploy.

## 6. Self-hosted GitHub Actions runner instead of GitHub-hosted

**Decision:** Registered a self-hosted runner on the same machine running
the kind cluster, rather than using GitHub's own hosted runners for the
deploy jobs.

**Why:** This is a hard requirement, not a preference - a `kind` cluster
only exists inside this machine's Docker daemon, with no public endpoint.
A GitHub-hosted runner (a random, different machine per job) has no way to
reach it at all. Note the `test` job still uses `ubuntu-latest`
(GitHub-hosted) since it doesn't need cluster access - only
`build-and-scan` and the three `deploy-*` jobs run on the self-hosted
runner, keeping the blast radius of "needs this specific machine" as small
as possible.

## 7. GHCR instead of AWS ECR for the container registry

**Decision:** Push images to `ghcr.io` rather than ECR.

**Why:** GHCR authenticates with the workflow's own built-in
`GITHUB_TOKEN` - zero extra secrets to configure, and no dependency on an
AWS account existing at all for a task that's explicitly allowed to run
without one (per the "not required" EKS constraint). If this moved to
EKS, ECR would be the natural choice instead (to use the same IAM-role-based,
credential-free pull pattern used in Round 1/2's EC2 deployment) - this is
purely a "what's the simplest correct choice given kind + self-hosted
runner" decision, not a statement that GHCR is preferred over ECR in general.

## 8. Not forcing `--platform linux/amd64` in this task's builds

**Decision:** Explicitly *not* repeating Round 1/2's `--platform
linux/amd64` flag here.

**Why:** In Round 1/2, the build machine (an Apple Silicon Mac) and the
deploy target (a real x86_64 EC2 instance) were different architectures,
so cross-compilation was required. Here, the self-hosted runner and the
kind cluster are the **same machine** - there's no cross-platform
deployment happening, so building natively (whatever architecture that
machine is) is correct, and forcing amd64 here would actually break
things on an ARM host by recreating the identical `exec format error`
Round 1 hit, just from the opposite direction. Documented explicitly
because it would be easy to copy-paste the old flag out of habit without
noticing the deploy target had changed.

## 9. Blue-green via Deployment `RollingUpdate` strategy, not two parallel Deployments

**Decision:** Implemented the "blue-green or canary" requirement using
`maxUnavailable: 0, maxSurge: 100%` on the existing single Deployment,
rather than maintaining two separate `api-blue`/`api-green` Deployment
objects with a Service selector that flips between them.

**Why:** The dual-Deployment approach gives finer control (e.g., true A/B
traffic splitting, keeping the old version's pods running indefinitely for
instant rollback rather than just via `rollout undo`), but is
meaningfully more manifest complexity for marginal benefit at this scale.
The chosen approach still delivers the core blue-green property that
actually matters: **the new version is fully up and passing readiness
probes before a single old pod is removed**, and a failed rollout never
receives production traffic in the first place because `scripts/deploy.sh`
only considers a rollout "successful" after `kubectl rollout status`
confirms it - a bad version is caught and auto-rolled-back before the
old, working ReplicaSet ever scales down. Documented here explicitly as a
deliberate scope tradeoff, not an oversight - the two-Deployment pattern is
the natural next step if instant zero-rollout-time rollback or gradual
traffic shifting becomes an actual requirement.

## 10. Postgres in-cluster (StatefulSet) instead of RDS

**Decision:** Run Postgres as a Kubernetes StatefulSet inside the cluster,
not as managed RDS.

**Why:** Running in-cluster is what the task's constraints describe
("Database: PostgreSQL or MySQL (managed or self-hosted)") and is the only
option that works at all for a local `kind` cluster (there's no AWS
account to attach an RDS instance to). This is explicitly flagged as the
**wrong** choice for real production disaster-recovery requirements in
`docs/runbooks/disaster-recovery.md`'s "Cluster failover strategy"
section - a single in-cluster Postgres pod is a single point of failure
that a backup script can't fully compensate for, and the honest
recommendation there is RDS Multi-AZ for a real deployment.

## 11. Trivy scan is report-only (non-blocking) in CI

**Decision:** `exit-code: '0'` on the Trivy scan step - findings are
captured in the workflow logs but don't fail the pipeline.

**Why:** `node:20-alpine` and `postgres:16-alpine` can both carry CVEs in
upstream OS packages that this project doesn't control the patch timing
for. Blocking every build on every CRITICAL/HIGH finding in a base image
would mean the pipeline is at the mercy of Alpine's own release cadence,
not this project's code. A more mature setup would block on a curated
allowlist (only fail for CVEs with an available fix that hasn't been
applied, or for findings in application-layer dependencies specifically)
- documented here as the honest reason for the current choice rather than
silently making scanning toothless.
