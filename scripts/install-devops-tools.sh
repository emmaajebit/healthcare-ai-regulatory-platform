#!/usr/bin/env bash
set -euo pipefail

# Idempotent installer for the DevOps toolchain.
# PEP-668 compliant: uses pipx for Python tools, never modifies system packages.

TERRAFORM_VERSION="1.8.5"
COSIGN_VERSION="2.2.4"
K6_VERSION="0.51.0"
ARGOCD_VERSION="2.11.3"

install_if_missing() {
  local cmd=$1; local install_fn=$2
  command -v "$cmd" &>/dev/null && echo "$cmd already installed, skipping." && return
  echo "Installing $cmd..."
  $install_fn
}

install_terraform() {
  local url="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
  curl -fsSL "$url" -o /tmp/terraform.zip
  unzip -o /tmp/terraform.zip -d /usr/local/bin/
  rm /tmp/terraform.zip
}

install_cosign() {
  local url="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64"
  curl -fsSL "$url" -o /usr/local/bin/cosign
  chmod +x /usr/local/bin/cosign
}

install_k6() {
  local url="https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-amd64.tar.gz"
  curl -fsSL "$url" | tar -xz -C /tmp/
  mv /tmp/k6-v${K6_VERSION}-linux-amd64/k6 /usr/local/bin/k6
}

install_argocd_cli() {
  local url="https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64"
  curl -fsSL "$url" -o /usr/local/bin/argocd
  chmod +x /usr/local/bin/argocd
}

install_if_missing terraform install_terraform
install_if_missing cosign   install_cosign
install_if_missing k6       install_k6
install_if_missing argocd   install_argocd_cli

echo "All tools installed successfully."
