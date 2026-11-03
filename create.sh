#!/usr/bin/env bash
# Check AWS credentials (prompt if missing), then terraform apply.
# Secrets go to ~/.aws (profile test-eks by default), never into this repository.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need aws terraform
ensure_aws_credentials
if [[ ! -f "$TF_DIR/versions.tf" ]]; then
  echo "Missing Terraform module at $TF_DIR" >&2
  exit 1
fi
if [[ ! -f "$TF_VARS" ]]; then
  need curl
  ADMIN_CIDR="${ADMIN_CIDR:-$(curl -fsS https://checkip.amazonaws.com)/32}"
  if [[ ! "$ADMIN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
    echo "Set ADMIN_CIDR to your public IPv4 address with /32." >&2
    exit 1
  fi
  write_lab_tfvars 1
fi
tf init -input=false
tf apply -input=false -auto-approve -var-file="$TF_VARS"
