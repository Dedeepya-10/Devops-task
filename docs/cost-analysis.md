# Cost Analysis

## Current actual cost: $0/month

This implementation runs on a local `kind` cluster, which is explicitly
allowed by the task's constraints and avoids real AWS billing entirely
while iterating. The estimates below are what this **same architecture**
would cost if deployed to real AWS EKS, since that's what the task is
actually asking to be costed out - a realistic production deployment, not
a $0 local demo. All prices are US East (N. Virginia), on-demand, as of
this task's writing; AWS pricing changes over time and should be
re-checked against the [AWS Pricing Calculator](https://calculator.aws)
before treating these as final.

## Architecture assumption for this estimate

**One EKS cluster, three namespaces** (development, staging, production) -
exactly what's built here - rather than three separate clusters. This is
itself the single biggest cost decision in this whole document (see
Optimization #1 below).

## Monthly cost breakdown

| Component | Spec | Monthly cost | Notes |
|---|---|---|---|
| EKS control plane | 1 cluster | $73.00 | Flat fee regardless of node count; shared across all 3 namespaces |
| Worker nodes | 3x t3.medium (2 vCPU/4GB) on-demand | $91.25 | $0.0417/hr x 730 hrs x 3 nodes; sized from this demo's actual resource quotas (dev 1 vCPU/1Gi, staging 2 vCPU/2Gi, prod 4 vCPU/4Gi + monitoring stack overhead) |
| RDS Postgres - production | db.t3.small, Multi-AZ | $59.42 | Multi-AZ for automatic failover (see disaster-recovery.md) - production gets its own instance, isolated from dev/staging |
| RDS Postgres - dev + staging | db.t3.micro, single-AZ, shared | $12.41 | Two databases on one shared instance - acceptable risk for non-production data |
| Application Load Balancer | 1 shared ALB, host/path routing | $16.20 + LCU usage (~$5 est.) | One ALB routing to all 3 environments by hostname, instead of 3 separate ALBs |
| EBS volumes | ~30GB total (Postgres data + Prometheus/Loki retention) | $3.00 | gp3 @ $0.08/GB-month |
| NAT Gateway | 1 shared, single AZ | $32.85 + data processing (~$10 est.) | Needed for private-subnet worker nodes to reach ECR/the internet; see Optimization #4 |
| Data transfer (inter-AZ, egress) | Estimated light load | ~$10.00 | Highly workload-dependent; this is a rough floor for a low-traffic demo-scale app |
| **Total** | | **≈ $313/month** | |

**By environment** (splitting the shared costs proportionally by resource
quota weight - development 1/7, staging 2/7, production 4/7 of the total
CPU quota, plus each environment's own dedicated RDS cost):

| Environment | Shared infra share | Dedicated RDS | Approx. monthly total |
|---|---|---|---|
| Development | ~$31 | (shared, see staging) | ~$31 |
| Staging | ~$62 | $12.41 (shared with dev, counted once above) | ~$74 |
| Production | ~$124 | $59.42 | ~$183 |

(Shared infra = control plane + nodes + ALB + NAT + EBS + data transfer,
split 1:2:4 to match the resource quota ratios in `terraform/variables.tf`.)

## Resource utilization analysis

Actual observed usage on the local cluster, from `kubectl top nodes` with
all three environments, the monitoring stack, and External Secrets Operator
all running simultaneously:

```
NAME                            CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
advanced-devops-control-plane   393m         9%       3096Mi          63%
```

This is on a constrained 4-CPU/5GB budget (deliberately small, to fit a
laptop). The **9% CPU utilization** is the more telling number: even with
every component from all three environments plus the full monitoring stack
running, actual CPU usage is a small fraction of what's provisioned. This
directly supports the resource quota numbers used above - they were sized
generously enough to avoid throttling, not padded arbitrarily, and this
observed low utilization is exactly the kind of signal that would justify
Optimization #2 and #3 below in a real account with a CloudWatch/Prometheus
history to look back on.

## Cost optimization strategies

1. **One shared EKS cluster instead of three.** Three separate clusters
   (one per environment) would mean three separate $73/month control
   planes - $146/month more than this design, before a single worker node
   is even counted. Namespace isolation (with the RBAC, network policies,
   and resource quotas already implemented here) provides most of the
   separation benefit of separate clusters at a fraction of the cost -
   the tradeoff is a shared blast radius for cluster-level failures, which
   is acceptable at this scale.

2. **Spot Instances for development and staging nodes.** Neither
   environment needs to survive an instance interruption gracefully the
   way production does - a Spot interruption just means a pod
   reschedules. Spot pricing for t3.medium typically runs 60-70% below
   on-demand, which on the ~$61/month of dev+staging node cost above could
   save roughly $35-40/month. Production stays on-demand (or a mix with
   Reserved Instances, see #5) since availability matters more there than
   the savings.

3. **Scale non-production environments down outside working hours.**
   Development (and arguably staging) doesn't need to run 24/7. A
   scheduled scale-down (e.g., a CronJob or Lambda scaling the `development`
   namespace's deployments to 0 replicas, or cordoning/draining a
   dedicated dev node group, overnight and on weekends) could cut
   development compute cost by roughly 60-70% (nights + weekends is about
   75% of a week's hours) for an environment that's realistically only
   used during working hours by a small team.

4. **VPC endpoints for ECR and S3 instead of routing through the NAT
   Gateway.** Pulling container images and writing backups to S3 through a
   NAT Gateway incurs NAT data-processing charges on top of the flat
   hourly fee. Gateway/interface VPC endpoints for S3 and ECR let that
   traffic stay inside the VPC, reducing NAT data-processing costs -
   meaningful once image pulls happen frequently (every deploy, across 3
   environments).

5. **Reserved Instances or a Savings Plan for the production node group,
   once there's a few months of stable usage data.** Production's load is
   the most predictable of the three environments (it doesn't get
   scaled to zero, and its resource quota is fixed). A 1-year Compute
   Savings Plan typically runs 30-40% below on-demand pricing for a
   commitment that's low-risk once the baseline is well understood -
   `Resource Utilization Analysis` above is exactly the kind of data
   that should be collected for a few months in a real account before
   committing.

## Resource quotas as a cost control (already implemented)

`terraform/variables.tf`'s per-environment `ResourceQuota` values
(`requests.cpu`, `requests.memory`, `limits.cpu`, `limits.memory`, `pods`)
aren't just a Kubernetes best practice - they're the mechanism that
actually prevents a runaway Deployment or a misconfigured HPA from quietly
scaling node count (and therefore the bill) far past what any environment
is supposed to cost. Production's quota (4 CPU / 4Gi requests) is a hard
ceiling on how far the HPA (`k8s/overlays/production/hpa.yaml`, min 3/max
10 `api` replicas) can actually scale before being blocked by the quota
itself, not just by the HPA's own `maxReplicas`.

## Cost monitoring strategy

- The `Namespace Resource Quotas` Grafana dashboard
  (`monitoring/grafana/dashboards/04-namespace-quotas.json`) already tracks
  quota usage per namespace in real time - the same numbers this document's
  environment-split cost table is derived from.
- In a real AWS account, **AWS Cost Explorer** with cost allocation tags
  (tagging every resource with `environment=development|staging|production`,
  which Terraform already does via each namespace's labels and could be
  extended to tag the underlying node groups/RDS instances identically)
  would give an actual per-environment cost breakdown to compare against
  the estimates in this document, instead of the proportional-split
  approximation used here.
- **Budget alerts** (AWS Budgets) per environment, set slightly above the
  estimated monthly costs in this document, would catch a cost regression
  (e.g., an HPA misconfiguration scaling far past expectations) before a
  full billing cycle passes.

## Recommendations for future scaling

- If traffic grows enough to need more than a handful of worker nodes,
  move from manually-sized node groups to **Karpenter** for
  just-in-time node provisioning - it right-sizes instance types to actual
  pending pod requirements instead of a fixed node group shape, which
  tends to reduce both waste and cost at higher scale.
- If the three environments' usage patterns diverge significantly (e.g.,
  staging starts needing production-like load for realistic testing),
  revisit the shared-cluster assumption this whole document is built on -
  the cost/isolation tradeoff that favors one cluster at this scale may
  not hold forever.
- Revisit RDS instance sizing using real `pg_stat` data once there's
  production traffic, rather than the demo-sized `db.t3.small` assumed
  above.
