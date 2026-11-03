#!/usr/bin/env bash
# Check AWS credentials (prompt if missing), then terraform destroy.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need aws terraform
ensure_aws_credentials
if [[ ! -f "$TF_DIR/versions.tf" ]]; then
  echo "Missing Terraform module at $TF_DIR" >&2
  exit 1
fi
tf init -input=false
if [[ -f "$TF_VARS" ]]; then
  tf destroy -input=false -auto-approve -var-file="$TF_VARS"
else
  echo "Missing $TF_VARS; destroying with cluster_name/region and a dummy admin_cidr." >&2
  tf destroy -input=false -auto-approve \
    -var="cluster_name=$CLUSTER_NAME" \
    -var="region=$AWS_REGION" \
    -var="admin_cidr=0.0.0.0/32"
fi
