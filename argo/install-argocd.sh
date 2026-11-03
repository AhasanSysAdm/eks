#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../common.sh"
check_context
COUNT="$(kubectl get nodes --no-headers | wc -l)"
if (( COUNT < 2 )); then
  echo "This small-node lab needs two workers for Argo CD: bash scale-workers.sh 2" >&2
  exit 1
fi
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace gitops-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
echo "Argo CD installed. Keep the UI local: kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "Read argo/README.md for the initial password, Helm lesson, and GitOps setup."
