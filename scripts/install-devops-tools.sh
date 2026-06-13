#!/usr/bin/env bash
# install-devops-tools.sh — One-click idempotent installer for the full
# healthcare-ai DevOps toolchain. Writes /tmp/tool-versions.json at the end
# so Ansible can consume installed versions as extra-vars or facts.
#
# Usage:
#   sudo bash scripts/install-devops-tools.sh
#   sudo bash scripts/install-devops-tools.sh --ansible-output   # also runs terraform-to-ansible.sh
#
# PEP-668 compliant: Python tools installed via pipx, never pip install --system.

set -euo pipefail

# ─── Pinned versions ──────────────────────────────────────────────────────────
TERRAFORM_VERSION="1.10.0"
AWSCLI_VERSION="2.17.20"
KUBECTL_VERSION="1.30.3"
HELM_VERSION="3.15.3"
EKSCTL_VERSION="0.187.0"
ARGOCD_VERSION="2.11.3"
COSIGN_VERSION="2.2.4"
K6_VERSION="0.51.0"
ANSIBLE_VERSION="10.2.0"   # ansible pip package (includes ansible-core)
JQ_VERSION="1.7.1"
YQ_VERSION="4.44.2"
CHECKOV_VERSION="3.2.225"

ARCH="amd64"
OS="linux"
BIN="/usr/local/bin"
VERSIONS_OUT="/tmp/tool-versions.json"

# ─── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { log "✓ $1"; }
skip() { log "→ $1 already installed, skipping."; }

installed() { command -v "$1" &>/dev/null; }

install_if_missing() {
  local cmd=$1
  local fn=$2
  if installed "$cmd"; then
    skip "$cmd"
  else
    log "Installing $cmd ..."
    $fn
    ok "$cmd"
  fi
}

require_root() {
  [[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)"; exit 1; }
}

# ─── Individual installers ────────────────────────────────────────────────────

install_base_deps() {
  log "Installing base dependencies (curl, unzip, gnupg, python3, pipx) ..."
  apt-get update -qq
  apt-get install -y -qq curl unzip gnupg software-properties-common \
    python3 python3-pip python3-venv pipx git jq
  pipx ensurepath
  ok "base deps"
}

install_terraform() {
  local url="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip"
  curl -fsSL "$url" -o /tmp/terraform.zip
  unzip -o /tmp/terraform.zip -d "$BIN"
  chmod +x "$BIN/terraform"
  rm /tmp/terraform.zip
}

install_awscli() {
  local url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  curl -fsSL "$url" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp/awscli-install
  /tmp/awscli-install/aws/install --update
  rm -rf /tmp/awscliv2.zip /tmp/awscli-install
}

install_kubectl() {
  local url="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  curl -fsSL "$url" -o "$BIN/kubectl"
  chmod +x "$BIN/kubectl"
}

install_helm() {
  local url="https://get.helm.sh/helm-v${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  curl -fsSL "$url" | tar -xz -C /tmp/
  mv "/tmp/${OS}-${ARCH}/helm" "$BIN/helm"
  chmod +x "$BIN/helm"
}

install_eksctl() {
  local url="https://github.com/eksctl-io/eksctl/releases/download/v${EKSCTL_VERSION}/eksctl_Linux_${ARCH}.tar.gz"
  curl -fsSL "$url" | tar -xz -C /tmp/
  mv /tmp/eksctl "$BIN/eksctl"
  chmod +x "$BIN/eksctl"
}

install_argocd() {
  local url="https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-${ARCH}"
  curl -fsSL "$url" -o "$BIN/argocd"
  chmod +x "$BIN/argocd"
}

install_cosign() {
  local url="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${ARCH}"
  curl -fsSL "$url" -o "$BIN/cosign"
  chmod +x "$BIN/cosign"
}

install_k6() {
  local url="https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-${OS}-${ARCH}.tar.gz"
  curl -fsSL "$url" | tar -xz -C /tmp/
  mv "/tmp/k6-v${K6_VERSION}-${OS}-${ARCH}/k6" "$BIN/k6"
  chmod +x "$BIN/k6"
}

install_yq() {
  local url="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_${OS}_${ARCH}"
  curl -fsSL "$url" -o "$BIN/yq"
  chmod +x "$BIN/yq"
}

install_ansible() {
  pipx install "ansible==${ANSIBLE_VERSION}"
  pipx inject ansible boto3 botocore kubernetes
}

install_checkov() {
  pipx install "checkov==${CHECKOV_VERSION}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

require_root

log "═══════════════════════════════════════════════════"
log " healthcare-ai DevOps toolchain bootstrap"
log " Terraform ${TERRAFORM_VERSION} | kubectl ${KUBECTL_VERSION} | Helm ${HELM_VERSION}"
log "═══════════════════════════════════════════════════"

install_base_deps

install_if_missing terraform  install_terraform
install_if_missing aws        install_awscli
install_if_missing kubectl    install_kubectl
install_if_missing helm       install_helm
install_if_missing eksctl     install_eksctl
install_if_missing argocd     install_argocd
install_if_missing cosign     install_cosign
install_if_missing k6         install_k6
install_if_missing yq         install_yq
install_if_missing ansible    install_ansible
install_if_missing checkov    install_checkov

# ─── Version snapshot → JSON (consumed by Ansible) ───────────────────────────

log "Writing tool versions to ${VERSIONS_OUT} ..."

cat > "$VERSIONS_OUT" <<EOF
{
  "tool_versions": {
    "terraform":  "$(terraform version -json 2>/dev/null | jq -r '.terraform_version' || echo "${TERRAFORM_VERSION}")",
    "aws_cli":    "$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2 || echo "${AWSCLI_VERSION}")",
    "kubectl":    "$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || echo "v${KUBECTL_VERSION}")",
    "helm":       "$(helm version --short 2>/dev/null || echo "v${HELM_VERSION}")",
    "eksctl":     "$(eksctl version 2>/dev/null || echo "${EKSCTL_VERSION}")",
    "argocd":     "$(argocd version --client --short 2>/dev/null | head -1 || echo "${ARGOCD_VERSION}")",
    "cosign":     "$(cosign version 2>/dev/null | head -1 || echo "${COSIGN_VERSION}")",
    "k6":         "$(k6 version 2>/dev/null | head -1 || echo "${K6_VERSION}")",
    "ansible":    "$(ansible --version 2>/dev/null | head -1 | awk '{print $NF}' || echo "${ANSIBLE_VERSION}")",
    "checkov":    "$(checkov --version 2>/dev/null || echo "${CHECKOV_VERSION}")",
    "yq":         "$(yq --version 2>/dev/null | awk '{print $NF}' || echo "${YQ_VERSION}")",
    "jq":         "$(jq --version 2>/dev/null || echo "jq-${JQ_VERSION}")"
  },
  "bootstrap_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bootstrap_host": "$(hostname -f 2>/dev/null || hostname)"
}
EOF

ok "Version snapshot written"

# ─── Optional: run Terraform → Ansible bridge ────────────────────────────────

if [[ "${1:-}" == "--ansible-output" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  log "Running terraform-to-ansible.sh ..."
  bash "${SCRIPT_DIR}/terraform-to-ansible.sh"
fi

log "═══════════════════════════════════════════════════"
log " Bootstrap complete. Tool versions:"
jq -r '.tool_versions | to_entries[] | "  \(.key): \(.value)"' "$VERSIONS_OUT"
log ""
log " Ansible can consume versions with:"
log "   ansible-playbook ... --extra-vars @${VERSIONS_OUT}"
log "═══════════════════════════════════════════════════"
