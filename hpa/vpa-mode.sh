#!/usr/bin/env bash
# Switch VPA updateMode on the AWS EKS lab cluster.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
check_context
case "${1:-}" in
  off) MODE=Off ;;
  initial)
    MODE=Initial
    TARGET="$(kubectl -n vpa-demo get vpa vertical-demo -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}')"
    if [[ -z "$TARGET" ]]; then
      echo "No VPA recommendation yet. Wait and inspect: kubectl -n vpa-demo describe vpa vertical-demo" >&2
      exit 1
    fi
    ;;
  *) echo "Usage: bash hpa/vpa-mode.sh off|initial" >&2; exit 1 ;;
esac
kubectl -n vpa-demo patch vpa vertical-demo --type merge \
  -p "{\"spec\":{\"updatePolicy\":{\"updateMode\":\"$MODE\"}}}"
if [[ "$MODE" == Initial ]]; then
  kubectl -n vpa-demo rollout restart deployment/vertical-demo
  kubectl -n vpa-demo rollout status deployment/vertical-demo --timeout=180s
fi
kubectl -n vpa-demo describe vpa vertical-demo
