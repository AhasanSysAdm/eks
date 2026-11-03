#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
need aws terraform session-manager-plugin
tf init -input=false
INSTANCE="$(tf output -raw bastion_instance_id)"
if [[ -z "$INSTANCE" || "$INSTANCE" == "None" ]]; then
  echo "No bastion instance in Terraform state. Run create.sh first." >&2
  exit 1
fi
ONLINE=false
for (( attempt=1; attempt<=60; attempt++ )); do
  STATUS="$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE" \
    --query 'InstanceInformationList[0].PingStatus' --output text)"
  if [[ "$STATUS" == Online ]]; then
    ONLINE=true
    break
  fi
  echo "Waiting for SSM registration ($attempt/60)..."
  sleep 10
done
if [[ "$ONLINE" != true ]]; then
  echo "Bastion did not register with SSM. Inspect EC2 status, IAM profile, and outbound internet access." >&2
  exit 1
fi
echo "Connecting to $INSTANCE."
echo "In the session: sudo cloud-init status --wait"
echo "Then: sudo su - ec2-user"
aws ssm start-session --target "$INSTANCE"
