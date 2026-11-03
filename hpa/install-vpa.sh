#!/usr/bin/env bash
# Install Vertical Pod Autoscaler controllers on the AWS EKS lab cluster.
# Scale to two workers first (scale-workers.sh 2) and delete hpa-demo.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need git openssl
check_context
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s
if kubectl get crd verticalpodautoscalers.autoscaling.k8s.io -o name --ignore-not-found | grep -q .; then
  echo "VPA already installed. Inspect its version; this script will not overwrite another installation." >&2
  exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
git clone --depth 1 --filter=blob:none --sparse --branch vertical-pod-autoscaler-1.6.0 \
  https://github.com/kubernetes/autoscaler.git "$WORK/autoscaler"
git -C "$WORK/autoscaler" sparse-checkout set vertical-pod-autoscaler
(
  cd "$WORK/autoscaler/vertical-pod-autoscaler"
  bash hack/vpa-up.sh
)
kubectl wait --for=condition=Established crd/verticalpodautoscalers.autoscaling.k8s.io --timeout=120s
for component in recommender updater admission-controller; do
  kubectl -n kube-system rollout status "deployment/vpa-$component" --timeout=300s
done
echo "VPA installed. Apply hpa/vpa-demo.yaml, then inspect recommendations."
