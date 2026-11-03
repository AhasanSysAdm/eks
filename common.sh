#!/usr/bin/env bash
# Shared lab settings for every provisioning script.
#
# Cost allocation: every AWS resource this lab creates is tagged
#   env=test-eks
# Activate the `env` tag under AWS Billing > Cost allocation tags, then filter
# Cost Explorer by that tag after the demo. Activation can take up to 24 hours
# and only applies to usage after the tag is active.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""
export CLUSTER_NAME="${CLUSTER_NAME:-academy-eks-demo}"
export NODEGROUP_NAME="demo-workers"
# Cost Explorer / Resource Groups filter. Keep these in sync with terraform/
# default_tags and the ECR CloudFormation Tags properties.
export COST_TAG_KEY="${COST_TAG_KEY:-env}"
export COST_TAG_VALUE="${COST_TAG_VALUE:-test-eks}"
# Profile used only when create.sh interactively saves access keys.
export LAB_AWS_PROFILE="${LAB_AWS_PROFILE:-test-eks}"
export TF_DIR="$LAB_ROOT/terraform"
export TF_VARS="$LAB_ROOT/.state/lab.tfvars"

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
  done
}

# Persist apply-time variables so scale/destroy keep the same admin_cidr.
write_lab_tfvars() {
  local desired="${1:-1}"
  mkdir -p "$LAB_ROOT/.state"
  cat > "$TF_VARS" <<EOF
cluster_name   = "$CLUSTER_NAME"
region         = "$AWS_REGION"
admin_cidr     = "$ADMIN_CIDR"
desired_size   = $desired
cost_tag_key   = "$COST_TAG_KEY"
cost_tag_value = "$COST_TAG_VALUE"
EOF
}

tf() {
  need terraform
  terraform -chdir="$TF_DIR" "$@"
}

# CloudFormation stack-level tags are copied onto taggable resources in the stack.
cfn_cost_tags() {
  printf 'Key=%s,Value=%s' "$COST_TAG_KEY" "$COST_TAG_VALUE"
}

aws_identity_ok() {
  aws sts get-caller-identity >/dev/null 2>&1
}

# If AWS CLI already has working credentials (env vars, default chain, or
# AWS_PROFILE), reuse them. Otherwise prompt. Access keys are stored in the
# local AWS CLI config under LAB_AWS_PROFILE (~/.aws), never in this repo.
ensure_aws_credentials() {
  need aws
  if aws_identity_ok; then
    echo "AWS credentials are already configured."
    aws sts get-caller-identity
    return 0
  fi

  echo "AWS credentials are not configured (aws sts get-caller-identity failed)."
  echo "This lab never writes keys into the repository."
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "Non-interactive session. Configure credentials, then rerun:" >&2
    echo "  aws configure --profile $LAB_AWS_PROFILE" >&2
    echo "  export AWS_PROFILE=$LAB_AWS_PROFILE" >&2
    echo "  # or: export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY [AWS_SESSION_TOKEN]" >&2
    echo "  # or: aws sso login --profile YOUR-PROFILE && export AWS_PROFILE=YOUR-PROFILE" >&2
    exit 1
  fi

  echo
  echo "How do you want to authenticate?"
  echo "  1) Access key ID + secret access key (optional session token)"
  echo "  2) Named profile / AWS SSO login"
  local choice
  read -r -p "Selection [1/2]: " choice
  case "$choice" in
    2)
      local profile
      read -r -p "AWS profile name [$LAB_AWS_PROFILE]: " profile
      profile="${profile:-$LAB_AWS_PROFILE}"
      export AWS_PROFILE="$profile"
      if ! aws_identity_ok; then
        echo "Starting aws sso login for profile $AWS_PROFILE ..."
        aws sso login --profile "$AWS_PROFILE"
      fi
      ;;
    *)
      local access_key secret_key session_token
      read -r -p "AWS Access Key ID: " access_key
      read -r -s -p "AWS Secret Access Key: " secret_key
      echo
      read -r -p "AWS Session Token (leave empty for long-lived keys): " session_token
      if [[ -z "$access_key" || -z "$secret_key" ]]; then
        echo "Access key and secret key are required." >&2
        exit 1
      fi
      aws configure set aws_access_key_id "$access_key" --profile "$LAB_AWS_PROFILE"
      aws configure set aws_secret_access_key "$secret_key" --profile "$LAB_AWS_PROFILE"
      aws configure set region "$AWS_REGION" --profile "$LAB_AWS_PROFILE"
      if [[ -n "$session_token" ]]; then
        aws configure set aws_session_token "$session_token" --profile "$LAB_AWS_PROFILE"
      fi
      export AWS_PROFILE="$LAB_AWS_PROFILE"
      echo "Saved credentials to AWS CLI profile '$LAB_AWS_PROFILE'."
      echo "Later commands (destroy.sh, connect-bastion.sh) need:"
      echo "  export AWS_PROFILE=$LAB_AWS_PROFILE"
      ;;
  esac

  if ! aws_identity_ok; then
    echo "AWS still rejected these credentials. Check the key, profile, or SSO session." >&2
    exit 1
  fi
  echo "Authenticated as:"
  aws sts get-caller-identity
}

# Apply env=test-eks to resources that templates might miss (VPC children,
# instance root volumes, ENIs, public IPv4 allocations, EKS cluster, ECR).
apply_lab_cost_tags() {
  local vpc="${1:-}"
  local tag_spec="Key=${COST_TAG_KEY},Value=${COST_TAG_VALUE}"
  echo "Applying cost tag ${COST_TAG_KEY}=${COST_TAG_VALUE} so Cost Explorer can filter this demo."

  if [[ -n "$vpc" && "$vpc" != "None" ]]; then
    local ids
    ids="$(
      {
        printf '%s\n' "$vpc"
        aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" \
          --query 'Subnets[].SubnetId' --output text
        aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" \
          --query 'InternetGateways[].InternetGatewayId' --output text
        aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" \
          --query 'RouteTables[].RouteTableId' --output text
        aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
          --query 'SecurityGroups[].GroupId' --output text
        aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
        aws ec2 describe-instances --filters "Name=vpc-id,Values=$vpc" \
          --query 'Reservations[].Instances[].InstanceId' --output text
        aws ec2 describe-instances --filters "Name=vpc-id,Values=$vpc" \
          --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' --output text
      } | tr '\t' '\n' | tr ' ' '\n' | awk 'NF && $0 != "None" && $0 != "null"'
    )"
    if [[ -n "$ids" ]]; then
      # Word-splitting is intentional: AWS CLI wants separate resource IDs.
      # shellcheck disable=SC2086
      aws ec2 create-tags --resources $ids --tags "$tag_spec"
    fi
  fi

  local cluster_arn
  cluster_arn="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.arn --output text)"
  if [[ -n "$cluster_arn" && "$cluster_arn" != "None" ]]; then
    aws eks tag-resource --resource-arn "$cluster_arn" --tags "${COST_TAG_KEY}=${COST_TAG_VALUE}"
  fi

  local repo repo_arn
  for repo in web php busybox nginx-cicd; do
    repo_arn="$(aws ecr describe-repositories --repository-names "${CLUSTER_NAME}/${repo}" \
      --query 'repositories[0].repositoryArn' --output text 2>/dev/null || true)"
    if [[ -n "$repo_arn" && "$repo_arn" != "None" ]]; then
      aws ecr tag-resource --resource-arn "$repo_arn" --tags "$tag_spec"
    fi
  done
}

check_identity() {
  need aws
  aws sts get-caller-identity
}

check_context() {
  need aws kubectl
  local expected actual
  expected="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.endpoint --output text)"
  actual="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Wrong kubectl cluster. HPA, VPA, Argo, and cicd/pipeline.sh run on this EKS lab cluster." >&2
    echo "Run: aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME --alias $CLUSTER_NAME" >&2
    exit 1
  fi
}
