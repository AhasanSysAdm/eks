#!/usr/bin/env bash
# create-dev-user.sh — IAM user + EKS access entry + namespace-scoped kubeconfig.
#
# Run from the instructor workstation (AWS admin creds), not on the bastion
# and not with sudo. The bastion role cannot create IAM users.
#
#   bash create-dev-user.sh
#   bash create-dev-user.sh alice alice-lab
#   bash create-dev-user.sh alice alice-lab --rotate
#
# Creates:
#   - IAM user ${CLUSTER_NAME}-dev-<name> (eks:DescribeCluster on this cluster)
#   - EKS access entry + AmazonEKSEditPolicy scoped to their namespace
#   - Kubernetes ClusterRole so kubectl get nodes/namespaces still works
#   - AWS CLI profile + kubeconfig under .state/dev-users/ (gitignored)
#
# The developer then (same public IP as ADMIN_CIDR, or they cannot reach the API):
#   export AWS_PROFILE=academy-eks-demo-dev-alice
#   export KUBECONFIG=.state/dev-users/alice.kubeconfig
#   kubectl get pods
set -euo pipefail
source "$(dirname "$0")/common.sh"
need aws kubectl
ensure_aws_credentials
check_context

CLUSTER_ROLE="academy-dev-cluster-read"
ROTATE=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "Usage: bash $0 [developer_name] [namespace] [--rotate]"
      echo "Creates an IAM user, EKS access entry, namespace, and kubeconfig."
      exit 0
      ;;
    --rotate) ROTATE=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

if [[ -n "${1:-}" ]]; then
  DEV_NAME="$1"
else
  read -r -p "Developer name (e.g. alice): " DEV_NAME
fi
if [[ -n "${2:-}" ]]; then
  NS="$2"
else
  read -r -p "Kubernetes namespace (e.g. alice-lab): " NS
fi

DEV_NAME="$(echo "$DEV_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
NS="$(echo "$NS" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"

if [[ ! "$DEV_NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
  echo "Invalid developer name. Use lowercase letters, digits, _ or - (start with a letter)." >&2
  exit 1
fi
if [[ ! "$NS" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Invalid namespace. Use DNS-1123 (lowercase, digits, dashes)." >&2
  exit 1
fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
IAM_USER="${CLUSTER_NAME}-dev-${DEV_NAME}"
DEV_PROFILE="${IAM_USER}"
PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT}:user/${IAM_USER}"
CLUSTER_ARN="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.arn --output text)"
OUT_DIR="$LAB_ROOT/.state/dev-users"
mkdir -p "$OUT_DIR"
KUBECONFIG_OUT="${OUT_DIR}/${DEV_NAME}.kubeconfig"
CREDS_OUT="${OUT_DIR}/${DEV_NAME}.env"

echo "==> Developer=${DEV_NAME}  namespace=${NS}  iam=${IAM_USER}"

if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
  echo "==> IAM user ${IAM_USER} already exists"
else
  aws iam create-user --user-name "$IAM_USER" \
    --tags "Key=${COST_TAG_KEY},Value=${COST_TAG_VALUE}" "Key=Project,Value=${CLUSTER_NAME}" \
    >/dev/null
  echo "==> Created IAM user ${IAM_USER}"
fi

aws iam put-user-policy --user-name "$IAM_USER" --policy-name DescribeLabCluster \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DescribeThisCluster",
      "Effect": "Allow",
      "Action": ["eks:DescribeCluster"],
      "Resource": "${CLUSTER_ARN}"
    }
  ]
}
EOF
)"

if [[ "$ROTATE" -eq 1 ]]; then
  OLD_KEYS="$(aws iam list-access-keys --user-name "$IAM_USER" \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text)"
  for key in $OLD_KEYS; do
    [[ -z "$key" || "$key" == "None" ]] && continue
    aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$key"
    echo "==> Deleted access key ${key}"
  done
fi

KEY_COUNT="$(aws iam list-access-keys --user-name "$IAM_USER" --query 'length(AccessKeyMetadata)' --output text)"
ACCESS_KEY_ID=""
SECRET_ACCESS_KEY=""
if [[ "$KEY_COUNT" == "0" ]]; then
  KEY_PAIR="$(aws iam create-access-key --user-name "$IAM_USER" \
    --query '[AccessKey.AccessKeyId,AccessKey.SecretAccessKey]' --output text)"
  ACCESS_KEY_ID="$(printf '%s\n' "$KEY_PAIR" | awk '{print $1}')"
  SECRET_ACCESS_KEY="$(printf '%s\n' "$KEY_PAIR" | awk '{print $2}')"
  umask 077
  cat > "$CREDS_OUT" <<EOF
AWS_PROFILE=${DEV_PROFILE}
AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}
AWS_REGION=${AWS_REGION}
CLUSTER_NAME=${CLUSTER_NAME}
NAMESPACE=${NS}
EOF
  echo "==> Wrote access keys to ${CREDS_OUT}"
else
  echo "==> Access keys already exist (secret cannot be retrieved). Use --rotate to mint a new pair."
  if [[ -f "$CREDS_OUT" ]]; then
    ACCESS_KEY_ID="$(sed -n 's/^AWS_ACCESS_KEY_ID=//p' "$CREDS_OUT")"
    SECRET_ACCESS_KEY="$(sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' "$CREDS_OUT")"
  fi
  if [[ -z "${ACCESS_KEY_ID}" || -z "${SECRET_ACCESS_KEY}" ]]; then
    echo "No saved keys at ${CREDS_OUT}. Re-run with --rotate." >&2
    exit 1
  fi
fi

aws configure set aws_access_key_id "$ACCESS_KEY_ID" --profile "$DEV_PROFILE"
aws configure set aws_secret_access_key "$SECRET_ACCESS_KEY" --profile "$DEV_PROFILE"
aws configure set region "$AWS_REGION" --profile "$DEV_PROFILE"

echo "==> Creating namespace ${NS}"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

if aws eks describe-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$PRINCIPAL_ARN" >/dev/null 2>&1; then
  echo "==> Access entry already exists for ${PRINCIPAL_ARN}"
else
  aws eks create-access-entry \
    --cluster-name "$CLUSTER_NAME" \
    --principal-arn "$PRINCIPAL_ARN" \
    --type STANDARD \
    --user-name "$DEV_NAME" \
    --kubernetes-groups "academy-dev" \
    >/dev/null
  echo "==> Created EKS access entry (kubernetes user ${DEV_NAME})"
fi

aws eks associate-access-policy \
  --cluster-name "$CLUSTER_NAME" \
  --principal-arn "$PRINCIPAL_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope "type=namespace,namespaces=${NS}" \
  >/dev/null
echo "==> Associated AmazonEKSEditPolicy on namespace ${NS}"

echo "==> Applying cluster-read ClusterRole (nodes / namespaces / PVs)"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTER_ROLE}
rules:
- apiGroups: [""]
  resources: ["nodes", "namespaces", "persistentvolumes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CLUSTER_ROLE}-${DEV_NAME}
subjects:
- kind: User
  name: ${DEV_NAME}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${CLUSTER_ROLE}
EOF

ENDPOINT="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.endpoint --output text)"
CA_DATA="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.certificateAuthority.data --output text)"
umask 077
cat > "$KUBECONFIG_OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${ENDPOINT}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    namespace: ${NS}
    user: ${DEV_NAME}
  name: ${DEV_NAME}@${CLUSTER_NAME}
current-context: ${DEV_NAME}@${CLUSTER_NAME}
users:
- name: ${DEV_NAME}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args:
        - --region
        - ${AWS_REGION}
        - eks
        - get-token
        - --cluster-name
        - ${CLUSTER_NAME}
        - --output
        - json
      env:
        - name: AWS_PROFILE
          value: ${DEV_PROFILE}
      interactiveMode: IfAvailable
      provideClusterInfo: false
EOF
chmod 600 "$KUBECONFIG_OUT" "$CREDS_OUT"

echo
echo "=============================================="
echo " Developer ready (EKS IAM user)"
echo "=============================================="
echo " IAM user     : ${IAM_USER}"
echo " Principal    : ${PRINCIPAL_ARN}"
echo " AWS profile  : ${DEV_PROFILE}"
echo " Namespace    : ${NS}"
echo " Access policy: AmazonEKSEditPolicy (this namespace only)"
echo " Kubeconfig   : ${KUBECONFIG_OUT}"
echo " Keys file    : ${CREDS_OUT}"
echo
echo " Use as the developer (workstation public IP must be ADMIN_CIDR):"
echo "   export AWS_PROFILE=${DEV_PROFILE}"
echo "   export KUBECONFIG=${KUBECONFIG_OUT}"
echo "   kubectl get pods"
echo "   kubectl get nodes"
echo "   kubectl auth can-i create deployments --namespace ${NS}"
echo "   kubectl -n kube-system get pods    # should be denied"
echo
echo " Do not run this on the bastion. Re-run with --rotate to mint new access keys."
echo "=============================================="
