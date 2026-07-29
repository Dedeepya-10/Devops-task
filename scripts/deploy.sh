#!/usr/bin/env bash
# Deploys a given commit SHA's images to one environment, waits for the
# rollout to actually succeed, and automatically rolls back if it doesn't.
#
# Usage: ./scripts/deploy.sh <development|staging|production> <image-tag>
set -euo pipefail

ENVIRONMENT="${1:?Usage: $0 <environment> <image-tag>}"
IMAGE_TAG="${2:?Usage: $0 <environment> <image-tag>}"
REGISTRY="${REGISTRY:-ghcr.io}"
REPO="${GITHUB_REPOSITORY:-$(git config --get remote.origin.url | sed -E 's#.*/([^/]+/[^/.]+)(\.git)?$#\1#')}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/../k8s/overlays/$ENVIRONMENT"

echo "==> Deploying commit $IMAGE_TAG to $ENVIRONMENT"

cd "$OVERLAY_DIR"
kustomize edit set image \
  "advanced-api=${REGISTRY}/${REPO}/api:${IMAGE_TAG}" \
  "advanced-worker=${REGISTRY}/${REPO}/worker:${IMAGE_TAG}"

kubectl apply -k .

echo "==> Waiting for rollout to complete"
if ! kubectl rollout status "deployment/api" -n "$ENVIRONMENT" --timeout=120s \
  || ! kubectl rollout status "deployment/worker" -n "$ENVIRONMENT" --timeout=120s; then
  echo "!! Rollout failed - automatically rolling back"
  kubectl rollout undo "deployment/api" -n "$ENVIRONMENT" || true
  kubectl rollout undo "deployment/worker" -n "$ENVIRONMENT" || true
  kubectl rollout status "deployment/api" -n "$ENVIRONMENT" --timeout=60s || true
  kubectl rollout status "deployment/worker" -n "$ENVIRONMENT" --timeout=60s || true
  echo "==> Rolled back to the previous version. Failing this job."
  exit 1
fi

echo "==> Rollout succeeded, running a health check inside the cluster"
API_POD="$(kubectl get pods -n "$ENVIRONMENT" -l app=api -o jsonpath='{.items[0].metadata.name}')"
if ! kubectl exec -n "$ENVIRONMENT" "$API_POD" -- \
  node -e "require('http').get('http://127.0.0.1:4000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"; then
  echo "!! Post-deploy health check failed - rolling back"
  kubectl rollout undo "deployment/api" -n "$ENVIRONMENT" || true
  kubectl rollout undo "deployment/worker" -n "$ENVIRONMENT" || true
  exit 1
fi

echo "==> $ENVIRONMENT is healthy on commit $IMAGE_TAG"
