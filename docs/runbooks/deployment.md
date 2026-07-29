# Runbook: Deployment Process

## Automatic deployment (the normal path)

Every push to `main` runs the full pipeline
(`.github/workflows/deploy.yml`):

```
test (lint + jest, api & worker)
   -> build-and-scan (build, Trivy scan, push to GHCR, kind load)
   -> deploy-development
   -> deploy-staging
   -> deploy-production (requires manual approval - see below)
```

Each `deploy-*` job runs `scripts/deploy.sh <environment> <commit-sha>`,
which:

1. Points that environment's Kustomize overlay at the newly-built image tag
2. Applies the manifests (`kubectl apply -k`)
3. Waits for the rollout to finish (`kubectl rollout status`)
4. **Automatically rolls back** (`kubectl rollout undo`) if the rollout
   times out or the post-deploy health check fails
5. Runs a real health check (`GET /health` executed inside the api pod)
   before declaring success

If any environment's deploy fails, later environments never get a chance
to deploy that commit - a bad build never makes it past whichever
environment first caught it.

## Approving a production deployment

Production is a protected GitHub Environment. Once `deploy-staging`
succeeds, the `deploy-production` job pauses and shows up under the
repo's **Actions** tab as "Waiting for review." A reviewer with access to
the `production` environment must approve it there before the job
actually runs. This is the "separate deployment approvals for production"
control - it's GitHub's own environment protection feature, not custom
code, which means it can't be silently bypassed by editing the workflow
file itself.

**To set this up on a fresh clone of this repo:** Settings -> Environments
-> `production` -> add required reviewers. This is a one-time, per-repo
manual step - the workflow YAML alone isn't enough on its own; it depends
on generic protection rules configured in the repo's settings.

## Manual deployment (if the pipeline is down, or for a hotfix)

```bash
./scripts/deploy.sh <development|staging|production> <image-tag>
```

Requires:
- `kubectl` pointed at the right cluster context (`kind-advanced-devops`
  for this local setup)
- The image already built and present (either `docker push`ed to the
  configured registry, or `kind load docker-image`ed directly if deploying
  to a local kind cluster)
- `kustomize` CLI on PATH (the script uses `kustomize edit set image`)

## Deploying a brand-new service (not api/worker/postgres)

1. Add a new directory under `k8s/base/<service-name>/` with its
   `deployment.yaml`, `service.yaml`, and `configmap.yaml`, following the
   same pattern as `k8s/base/api/`.
2. Add those three files to `k8s/base/kustomization.yaml`'s `resources:` list.
3. Add any environment-specific replica/resource patches to each of the
   three overlays (`k8s/overlays/{development,staging,production}/kustomization.yaml`).
4. If the service needs its own database credentials or other secrets,
   add a corresponding entry in the `secrets-source` namespace and a new
   `ExternalSecret` in `k8s/secrets/` - see `secret-management.md`.
5. If the service is meant to be scraped by Prometheus, add the
   `prometheus.io/scrape: "true"`, `prometheus.io/port`, and
   `prometheus.io/path` annotations to its pod template, matching the
   pattern in `k8s/base/api/deployment.yaml`.
6. Add it to the CI/CD workflow's `matrix.service` lists (`test` and
   `build-and-scan` jobs) so it gets tested, built, scanned, and deployed
   the same way as api/worker.

## How to update a ConfigMap

Environment-specific configuration lives in each overlay's
`configMapGenerator` block (`k8s/overlays/<env>/kustomization.yaml`), not
in the base manifests - e.g. `LOG_LEVEL` differs per environment (`debug`
in development, `warn` in production). To change a value:

1. Edit the relevant `literals:` entry in that environment's
   `kustomization.yaml`.
2. Commit and push - the next pipeline run applies it. `kubectl apply -k`
   is safe to re-run at any time; unchanged resources are left alone.

Because `configMapGenerator` content-hashes the ConfigMap name by default
(disabled here in favor of stable names for simplicity), pods **do not
automatically restart** when a ConfigMap value changes underneath them - a
`kubectl rollout restart deployment/<name> -n <env>` is needed after a
config-only change if the new value needs to take effect immediately.
