#!/usr/bin/env bash
# Scale the managed node group via Terraform (source of truth). Extra workers
# inherit env=test-eks from provider default_tags.
set -euo pipefail
source "$(dirname "$0")/common.sh"
need terraform
check_context
case "${1:-}" in
  1|2) COUNT="$1" ;;
  *) echo "Usage: bash scale-workers.sh 1|2 (EC2 billing changes)" >&2; exit 1 ;;
esac
if [[ ! -f "$TF_VARS" ]]; then
  echo "Missing $TF_VARS. Run create.sh first so admin_cidr is preserved." >&2
  exit 1
fi
ADMIN_CIDR="$(awk -F'"' '/admin_cidr/ {print $2; exit}' "$TF_VARS")"
if [[ ! "$ADMIN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
  echo "Could not read admin_cidr from $TF_VARS" >&2
  exit 1
fi
tf init -input=false
write_lab_tfvars "$COUNT"
tf apply -input=false -auto-approve -var-file="$TF_VARS"
kubectl get nodes -o wide
