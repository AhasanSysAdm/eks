#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need aws docker
TAG="${1:-}"
if [[ ! "$TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
  echo "Usage: bash ecr/build-push.sh UNIQUE_TAG (example: demo-20261102-1)" >&2
  exit 1
fi
# Fail before obtaining credentials if the engine is unavailable.
docker info >/dev/null
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
# Keep the short-lived ECR token out of the user's persistent Docker config.
export DOCKER_CONFIG="$WORK"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
for APP in web php busybox; do
  case "$APP" in
    web) BASE=nginx:1.28-alpine ;;
    php) BASE=php:8.3-apache ;;
    busybox) BASE=busybox:1.36 ;;
  esac
  IMAGE="$REGISTRY/$CLUSTER_NAME/$APP:$TAG"
  # Workers are x86 t3.small, even though the bastion is ARM.
  docker build --platform linux/amd64 --pull --build-arg "BASE_IMAGE=$BASE" \
    -t "$IMAGE" -f "$LAB_ROOT/ecr/Dockerfile" "$LAB_ROOT/ecr"
  docker push "$IMAGE"
  echo "Published $IMAGE"
done
echo "Update deployment references: python ecr/update-images.py --registry $REGISTRY --cluster $CLUSTER_NAME --tag $TAG"
