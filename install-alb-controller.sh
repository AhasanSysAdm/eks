#!/usr/bin/env bash
# Install AWS Load Balancer Controller (IngressClass alb).
# Run from the instructor workstation after create.sh, with kubeconfig set.
# Terraform already created the IRSA role; this Helm release uses it.
#
#   bash install-alb-controller.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
need aws kubectl helm terraform
ensure_aws_credentials
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME"
check_context

tf init -input=false >/dev/null
ROLE_ARN="$(tf output -raw alb_controller_role_arn 2>/dev/null || true)"
VPC_ID="$(tf output -raw vpc_id 2>/dev/null || true)"
if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" || -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "Missing Terraform outputs alb_controller_role_arn / vpc_id." >&2
  echo "Re-apply: bash create.sh   (adds EKS OIDC + ALB controller IAM)" >&2
  exit 1
fi

echo "Installing AWS Load Balancer Controller (creates internet-facing ALBs when Ingress is applied)."
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update eks >/dev/null
VALUES="$(mktemp)"
trap 'rm -f -- "$VALUES"' EXIT
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

kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=180s
kubectl -n kube-system get deploy,pods -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get ingressclass alb
echo
echo "ALB controller is ready. IngressClass: alb"
echo "Apply a demo:  kubectl apply -f 16-ingress.yaml"
echo "Then:          kubectl -n manifest-demo get ingress web"
