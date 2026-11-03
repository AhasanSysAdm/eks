#!/usr/bin/env bash
# Classroom CI/CD: build nginx with baked-in app version, push to ECR, deploy
# Deployment + Service + ALB Ingress, then print the version from the ALB URL.
#
#   bash cicd/pipeline.sh 1
#   bash cicd/pipeline.sh 2
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need aws docker kubectl helm curl terraform
ensure_aws_credentials
check_context
docker info >/dev/null

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,31}$ ]]; then
  echo "Usage: bash cicd/pipeline.sh <version>   (example: 1 then 2)" >&2
  exit 1
fi
EXPECTED="app version ${VERSION}"
TAG="v${VERSION}"
REPO_NAME="${CLUSTER_NAME}/nginx-cicd"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE="${REGISTRY}/${REPO_NAME}:${TAG}"
CICD_DIR="$LAB_ROOT/cicd"

tf init -input=false >/dev/null
ROLE_ARN="$(tf output -raw alb_controller_role_arn 2>/dev/null || true)"
VPC_ID="$(tf output -raw vpc_id 2>/dev/null || true)"
if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" || -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "Missing Terraform outputs alb_controller_role_arn / vpc_id." >&2
  echo "Re-apply: bash create.sh   (adds EKS OIDC + ALB controller IAM)" >&2
  exit 1
fi

if ! aws ecr describe-repositories --repository-names "$REPO_NAME" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "$REPO_NAME" \
    --image-tag-mutability IMMUTABLE \
    --encryption-configuration encryptionType=AES256 \
    --image-scanning-configuration scanOnPush=true \
    --tags "Key=${COST_TAG_KEY},Value=${COST_TAG_VALUE}" "Key=Project,Value=${CLUSTER_NAME}" \
    >/dev/null
  echo "Created ECR repository $REPO_NAME"
fi

if ! kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1; then
  echo "Installing AWS Load Balancer Controller (creates internet-facing ALBs)."
  helm repo add eks https://aws.github.io/eks-charts >/dev/null
  helm repo update eks >/dev/null
  VALUES="$(mktemp)"
  cat > "$VALUES" <<EOF
clusterName: ${CLUSTER_NAME}
region: ${AWS_REGION}
vpcId: ${VPC_ID}
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
enableShield: false
enableWaf: false
enableWafv2: false
EOF
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --version 1.13.4 \
    -f "$VALUES" \
    --wait --timeout 5m
  rm -f -- "$VALUES"
fi
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=180s

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
export DOCKER_CONFIG="$WORK"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

if aws ecr describe-images --repository-name "$REPO_NAME" \
    --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
  echo "Using already-published $IMAGE"
else
  docker build --platform linux/amd64 --pull \
    --build-arg "APP_VERSION=$VERSION" \
    -t "$IMAGE" -f "$CICD_DIR/Dockerfile" "$CICD_DIR"
  docker push "$IMAGE"
  echo "Published $IMAGE"
fi

sed "s|__IMAGE__|$IMAGE|g" "$CICD_DIR/k8s.yaml" > "$WORK/k8s.yaml"
kubectl apply -f "$WORK/k8s.yaml"
kubectl -n cicd-demo rollout status deployment/nginx-cicd --timeout=180s

echo "Waiting for ALB hostname (billable Application Load Balancer)..."
HOST=""
for (( attempt=1; attempt<=60; attempt++ )); do
  HOST="$(kubectl -n cicd-demo get ingress nginx-cicd \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "$HOST" ]]; then
    break
  fi
  echo "ALB not ready ($attempt/60)..."
  sleep 10
done
if [[ -z "$HOST" ]]; then
  echo "Ingress never received an ALB hostname. Check controller logs in kube-system." >&2
  exit 1
fi
URL="http://${HOST}/"
echo "Ingress endpoint: $URL"

BODY=""
for (( attempt=1; attempt<=60; attempt++ )); do
  if BODY="$(curl -fsS --max-time 10 "$URL" 2>/dev/null)"; then
    BODY="$(printf '%s' "$BODY" | tr -d '\r')"
    if grep -Fq "$EXPECTED" <<<"$BODY"; then
      printf '%s\n' "$BODY"
      echo "CI/CD demo OK: $URL printed: $EXPECTED"
      exit 0
    fi
    echo "ALB reachable but body is not yet '$EXPECTED' ($attempt/60): $BODY"
  else
    echo "Waiting for ALB HTTP 200 ($attempt/60)..."
  fi
  sleep 10
done
echo "Timed out waiting for '$EXPECTED' from $URL" >&2
exit 1
