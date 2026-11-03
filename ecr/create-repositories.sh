#!/usr/bin/env bash
# Create private ECR repositories. Repos and the stack are tagged env=test-eks.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
check_identity
aws cloudformation deploy --stack-name "${CLUSTER_NAME}-ecr" \
  --template-file "$LAB_ROOT/ecr/repositories.yaml" \
  --tags "$(cfn_cost_tags)" \
  --parameter-overrides "ClusterName=$CLUSTER_NAME"
