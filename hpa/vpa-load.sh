#!/usr/bin/env bash
# CPU load marker for the VPA demo on the AWS EKS lab cluster.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
check_context
stop_load() {
  kubectl -n vpa-demo exec deployment/vertical-demo -- rm -f /tmp/load
}
trap stop_load EXIT
kubectl -n vpa-demo exec deployment/vertical-demo -- touch /tmp/load
echo "CPU load enabled for 300 seconds. Ctrl+C also clears the load marker."
sleep 300
