# Advanced DevOps Challenge — Submission Notes

This is my write-up for the Advanced challenge. The repo's `README.md` and
`docs/` folder have the full technical reference (architecture diagrams,
decision log, cost analysis, runbooks) — this is more of a walkthrough of
what I actually built, the calls I made along the way, and what actually
went wrong while getting it working.

## What I built

Three services — an API, a background worker, and Postgres — deployed
across three properly isolated Kubernetes namespaces (development,
staging, production), each with its own resource quotas, network
policies, and RBAC. On top of that: a full Prometheus/Grafana/Loki
monitoring stack, External Secrets Operator for credential management, a
CI/CD pipeline that actually deploys through all three environments with
a manual approval gate in front of production, and disaster recovery
scripts I tested for real rather than just describing.

Everything runs on a local `kind` cluster rather than real AWS EKS. The
task explicitly allows this, and it meant I could actually iterate and
test everything within the time limit instead of burning hours waiting on
EKS control planes to come up, and it meant zero AWS billing risk for a
task where no production traffic ever needed to touch it. Every piece —
Terraform, the Kubernetes manifests, the CI/CD pipeline — is written so
the path to real EKS is a small, specific set of changes, and I documented
exactly what those changes would be rather than pretending kind and EKS
are the same thing.

## The three environments, briefly

Development gets 1 replica of everything and default settings. Staging
gets 2 API replicas. Production gets 3-10 API replicas and 2-6 worker
replicas under a HorizontalPodAutoscaler, a `restricted` Pod Security
Standard instead of `baseline`, and its own resource quota ceiling. The
full comparison table is in `README.md` — the point I want to make here
is that these aren't arbitrary numbers, they come from the actual
Terraform `ResourceQuota` definitions and Kustomize overlay patches, and I
checked real cluster resource usage (`kubectl top nodes`) throughout to
make sure they were realistic rather than guessed.

## Monitoring

Prometheus, Grafana, and Loki, with 5 custom dashboards and 12 alert
rules (CPU/memory pressure, pod crashes, deployment failures, HPA maxed
out, Postgres down, worker stalled, resource quota exhaustion, and a few
more). I picked Loki over a full ELK stack specifically because this runs
on an 8GB laptop — Elasticsearch alone wants more memory than that leaves
for everything else combined, and Loki gives the same "centralized logs
searchable from Grafana" outcome without the footprint. That's a
documented tradeoff, not an oversight.

![Prometheus targets showing real scrape jobs across all three namespaces](docs/images/prometheus-targets.png)

![All 12 custom alert rules loaded and evaluating cleanly](docs/images/prometheus-alerts.png)

![One of the 5 custom Grafana dashboards, showing real per-namespace worker data](docs/images/worker-service-dashboard.png)

## Secrets, and a rotation I actually had to fix

I stood up External Secrets Operator with a separate namespace standing in
for what would be AWS Secrets Manager in production — real `ExternalSecret`
objects syncing on a 1-minute refresh interval, not just a design doc.

The part worth calling out: I set this up *after* Postgres was already
running with a different, statically-set password. Rotating the secret
didn't actually fix authentication — Postgres only applies
`POSTGRES_PASSWORD` at first database initialization, so the live database
kept expecting the old password no matter what the newly-synced Secret
said. I had to run an explicit `ALTER USER` against each environment's
running Postgres to bring it in line, then restart the pods that read the
secret as environment variables (which also don't live-reload). I wrote
the exact sequence into `docs/runbooks/secret-management.md` because it's
exactly the kind of thing that looks fine in a demo and then quietly
breaks the first time someone rotates a credential for real.

## CI/CD — and where it actually broke

The pipeline runs on a self-hosted GitHub Actions runner registered on the
same machine as the kind cluster, because a GitHub-hosted runner has no
network path to a cluster that only exists inside this machine's Docker
daemon. That part worked on the first try. Getting the actual build job
green took three more attempts, and I think the failures are worth being
honest about since they're genuinely instructive:

1. **`aquasecurity/trivy-action@0.28.0`** — I'd written the version
   without the `v` prefix the project's git tags actually use. Simple typo,
   immediate failure at job setup.
2. **`aquasecurity/trivy-action@v0.29.0`** — fixed the prefix, but that
   specific release pins an *internal* dependency
   (`aquasecurity/setup-trivy@v0.2.2`) that no longer exists upstream —
   the tag had been deleted or renamed since that release was cut. Not
   something I could have caught by reading my own YAML more carefully;
   I had to check the newer release's `action.yaml` and confirm it pins its
   internal dependency by commit SHA instead of a floating tag before
   trusting it wouldn't rot the same way.
3. **The real one**: `docker build -t ghcr.io/${{ github.repository }}/...`
   failed outright once it got past the action-resolution problems, because
   `github.repository` preserves this repo's actual name
   (`Dedeepya-10/Devops-task`), and Docker/GHCR image references have to be
   all lowercase. GitHub Actions' expression language has no built-in
   lowercase function, so I added a step that computes it once via `tr` and
   stores it in `$GITHUB_ENV`, and made `scripts/deploy.sh` do the same
   lowercasing independently so it behaves identically whether it's invoked
   by CI or run by hand.

After that fix, the full pipeline ran clean end to end: lint/test both
services, build, Trivy scan, push to GHCR, deploy to development, deploy
to staging, pause for my manual approval on production, then deploy to
production. I checked afterward that the production pods were actually
running the image tagged with that exact commit SHA — not just that the
job said "success."

![Production environment protection rule requiring manual approval](docs/images/github-production-approval.png)

## Disaster recovery — actually tested, not just described

I didn't want to just write a runbook that claims backup/restore works —
I ran it. Created two real items through the API in the staging
environment, backed up the database, deliberately truncated the tables to
simulate real data loss, confirmed the data was actually gone, restored
from the backup, and confirmed the exact same rows came back (same IDs,
same timestamps). That whole cycle took under two minutes. The full
transcript is in `docs/runbooks/disaster-recovery.md`, including the RTO/RPO
targets and the honest limitation that a single-node local cluster can't
test real multi-AZ cluster failover — that part is a documented design
for real EKS + RDS Multi-AZ, not something I could actually exercise here.

## Cost analysis

Actual cost right now is $0, since this runs locally. `docs/cost-analysis.md`
has a full projected AWS cost breakdown (~$313/month) if this exact
architecture were deployed to real EKS, split by environment, plus five
concrete cost optimization strategies — the biggest one being that this
uses one shared cluster with three namespaces instead of three separate
clusters, which alone avoids roughly $146/month in duplicate EKS control
plane costs.

## What I'd add given more time

- Real Alertmanager routing to Slack/PagerDuty instead of just the
  Prometheus/Alertmanager UI
- `postgres_exporter` for actual query-level database metrics
- Scheduled backups instead of manually-triggered ones
- The two-Deployment blue-green pattern (separate blue/green Deployments
  with a Service selector flip) instead of the rolling-update-based
  cutover I used, if true zero-rollout-time rollback or gradual traffic
  splitting becomes an actual requirement
