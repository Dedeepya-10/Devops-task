# Runbook: Scaling Procedures

## Automatic scaling (production only)

Production's `api` and `worker` Deployments have HorizontalPodAutoscalers
(`k8s/overlays/production/hpa.yaml`):

| Workload | Min replicas | Max replicas | Scales on |
|---|---|---|---|
| `api` | 3 | 10 | 70% CPU or 80% memory utilization |
| `worker` | 2 | 6 | 70% CPU utilization |

Development and staging deliberately have **no HPA** - they run a fixed
replica count (1 and 2 respectively) since their purpose is testing
correctness, not handling variable load.

**To watch autoscaling activity:**
```bash
kubectl get hpa -n production -w
```
or the "Autoscaling (Production HPA)" Grafana dashboard
(`monitoring/grafana/dashboards/05-autoscaling.json`), which plots current
vs. desired vs. min/max replicas over time.

**If the HPA is maxed out** (`HPAMaxedOut` alert firing, or
`current == max` in `kubectl get hpa`): this means real sustained load is
hitting the ceiling. Either raise `maxReplicas` in `hpa.yaml` (and confirm
`production`'s `ResourceQuota` in `terraform/variables.tf` has enough
headroom for that many more pods - the quota is a hard ceiling
independent of the HPA's own max), or investigate whether the load
increase itself is expected/legitimate before just scaling further.

## Manual scaling

```bash
kubectl scale deployment/api -n <environment> --replicas=<n>
```

Note: manually scaling a Deployment that has an HPA attached (production's
`api`/`worker`) is a temporary override - the HPA will scale it back
according to its own min/max and current metrics on its next evaluation
cycle (every 15s by default). To make a scaling change durable, edit
`minReplicas`/`maxReplicas` in `hpa.yaml` instead of scaling manually.

## Vertical scaling (changing CPU/memory requests-limits)

Per-environment resource requests/limits are set via JSON patches in each
overlay's `kustomization.yaml` (`patches:` targeting the Deployment/
StatefulSet). To change them:

1. Edit the relevant `resources:` block in
   `k8s/overlays/<env>/kustomization.yaml`.
2. Check the change fits inside that environment's `ResourceQuota`
   (`terraform/variables.tf` -> `var.environments`) - `kubectl apply -k`
   will be rejected by the API server if it doesn't, which is exactly the
   quota doing its job of preventing an accidental cost blowout.
3. Apply: `kubectl apply -k k8s/overlays/<env>`.

## Scaling the cluster itself (nodes)

This demo's kind cluster is single-node by design (a resource-constrained
laptop, not meant to represent production node scaling - see
`docs/architecture.md`). On real EKS, node-level scaling would be handled
by Cluster Autoscaler or Karpenter reacting to pending, unschedulable pods
- see the "Recommendations for future scaling" section of
`docs/cost-analysis.md`.

## Database scaling

The current architecture runs Postgres as a single in-cluster
StatefulSet - it doesn't scale horizontally at all, by design, since
Postgres isn't natively horizontally scalable for writes. If read load
becomes the bottleneck, the correct next step is read replicas (native
Postgres streaming replication, or migrating to RDS with read replica
support) rather than trying to add more StatefulSet replicas, which would
just create independent, non-synchronized databases.
