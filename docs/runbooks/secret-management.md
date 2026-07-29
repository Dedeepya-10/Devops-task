# Runbook: Secret Management

## Architecture

```
secrets-source namespace (stands in for AWS Secrets Manager)
  Secret: db-credentials-development  ---\
  Secret: db-credentials-staging       ---+--> External Secrets Operator --> Secret: db-credentials
  Secret: db-credentials-production   ---/         (ClusterSecretStore:        (in each of dev/staging/prod,
                                                      secrets-source-store)      synced every 1 minute)
```

Real credential **values** live in exactly one place: the `secrets-source`
namespace. Nothing in `development`/`staging`/`production` stores a secret
value directly in git or in a manifest - each namespace's `db-credentials`
Secret is created and kept in sync by an `ExternalSecret` object
(`k8s/secrets/external-secret-<env>.yaml`), which pulls from
`secrets-source` via a `ClusterSecretStore`
(`k8s/secrets/cluster-secret-store.yaml`).

**Why a namespace instead of real AWS Secrets Manager:** this demo runs on
a local kind cluster with no real AWS account behind it. External Secrets
Operator's `kubernetes` provider (used here) and its `aws.secretsManager`
provider (what production would use) are configured identically from
`ExternalSecret`'s point of view - only the `ClusterSecretStore.spec.provider`
block changes. See "Moving this to real AWS Secrets Manager" below for
the exact diff.

## Access control

The `eso-reader` ServiceAccount (in `secrets-source`, created by
`terraform/main.tf`) is the **only** identity that can read secrets out of
`secrets-source` - it has a `Role` scoped to `get/list/watch` on `secrets`
in that one namespace, nothing else. Nothing in `development`/`staging`/
`production` has any RBAC permission to read `secrets-source` directly;
they only ever see the already-synced, namespace-local `db-credentials`
Secret. This is also why the `deployer`/`developer`/`viewer` Roles defined
for the app namespaces (`terraform/main.tf`) deliberately don't include
`secrets` as a resource at all - not even the CI/CD pipeline's own
ServiceAccount can read secret values, only reference them by name in a
Deployment spec.

## Rotating a credential

1. Update the value in `secrets-source`:
   ```bash
   kubectl create secret generic db-credentials-<env> \
     --from-literal=POSTGRES_USER=appuser \
     --from-literal=POSTGRES_PASSWORD=<new-password> \
     --from-literal=POSTGRES_DB=appdb \
     -n secrets-source --dry-run=client -o yaml | kubectl apply -f -
   ```
2. Within the `ExternalSecret`'s `refreshInterval` (1 minute), the
   namespace's `db-credentials` Secret updates automatically. Confirm:
   ```bash
   kubectl get secret db-credentials -n <env> -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
   ```
3. **Update the actual Postgres user password to match** - this is the
   step that's easy to forget, and the one that actually caused a real
   outage-in-miniature while building this:
   ```bash
   kubectl exec -n <env> postgres-0 -- psql -U appuser -d appdb \
     -c "ALTER USER appuser WITH PASSWORD '<new-password>';"
   ```
   Postgres only applies `POSTGRES_PASSWORD` from its environment at
   first-ever startup (`initdb` time) - changing the Secret afterward does
   **not** change the already-running database's stored password. Skipping
   this step means the newly-rotated Secret and the actual database
   disagree, and every subsequent connection attempt fails auth.
4. Restart `api` and `worker` so they pick up the new value (env vars from
   `secretKeyRef` are read once at pod start, not live-reloaded):
   ```bash
   kubectl rollout restart deployment/api deployment/worker -n <env>
   ```

**This exact sequence was run for real** while building this project -
after standing up External Secrets Operator on top of an already-running
Postgres (initialized with a different, static password), the rotation
above was necessary to bring the live database in line with the newly
ESO-managed secret, and was verified by confirming `GET /api/items` still
worked afterward.

## Moving this to real AWS Secrets Manager

Only `k8s/secrets/cluster-secret-store.yaml`'s `spec.provider` block
changes - every `ExternalSecret` stays exactly as-is:

```yaml
# Instead of:
#   provider:
#     kubernetes: { remoteNamespace: secrets-source, ... }
# use:
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: eso-reader   # annotated with an IAM role via IRSA
```

The IAM role behind that ServiceAccount would need
`secretsmanager:GetSecretValue` scoped to only the specific secret ARNs
for this application - the same least-privilege principle already applied
to the `kubernetes`-provider version's RBAC `Role`.

## Container image scanning

`docker/build-push-action` in CI is followed by a Trivy scan
(`aquasecurity/trivy-action`) against the exact image tag just built,
before it's pushed. Currently configured to report (not block) on
`CRITICAL`/`HIGH` findings - see the comment in
`.github/workflows/deploy.yml` for why (upstream base-image CVEs outside
this project's control), and the full results appear in that workflow
run's logs as real evidence, not just a pass/fail checkbox.
