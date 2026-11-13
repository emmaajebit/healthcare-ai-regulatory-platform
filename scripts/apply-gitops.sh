#!/usr/bin/env bash
# apply-gitops.sh — apply the ArgoCD Applications (app-of-apps) to the cluster.
# Run AFTER `make k8s` has installed ArgoCD (Ansible playbook).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required"; exit 1; }

echo ">> Applying ArgoCD Applications (app-of-apps)"
kubectl apply -f "$PROJECT_ROOT/kubernetes/argocd/app-of-apps.yaml"

echo ">> ArgoCD now manages itself and java-healthcare-app via GitOps."
echo "   Watch with: kubectl -n argocd get applications -w"
