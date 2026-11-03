#!/usr/bin/env bash
# Install Metrics Server on the AWS EKS lab cluster so HPA/VPA can read CPU/memory.
# Requires kubectl to match CLUSTER_NAME (see check_context). Not for MicroK8s.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
check_context
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.1/components.yaml
kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s
kubectl top nodes
