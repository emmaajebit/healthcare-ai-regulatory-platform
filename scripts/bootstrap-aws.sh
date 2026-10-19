#!/usr/bin/env bash
# bootstrap-aws.sh — one-time platform bootstrap for the healthcare-ai PoC.
#
# Implements README steps 2–5 end to end:
#   1. Creates the KMS key + alias used for state encryption
#   2. Creates the S3 state bucket (versioning + KMS encryption + public
#      access block) required by the Terraform 1.10 use_lockfile backend
#   3. Runs terraform init + apply (VPC, EKS, ECR, OpenSearch, WORM bucket,
#      DynamoDB audit log, GitHub OIDC provider + deployer/planner roles)
#   4. Sets the GitHub Actions repository variables from Terraform outputs
#   5. Points the ArgoCD Application manifest at the real ECR registry
#   6. Optionally seeds a real ArgoCD admin password in Secrets Manager
#
# Prerequisites: aws CLI (admin credentials), terraform >= 1.10, gh CLI.
# After this script succeeds, GitHub Actions authenticates keylessly —
# no long-lived AWS credentials are stored anywhere.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET="healthcare-ai-terraform-state"
REGION="us-east-1"
KMS_ALIAS="alias/healthcare-ai-terraform-state"

GITHUB_REPO="${GITHUB_REPO:-$(basename "$PROJECT_ROOT")}"
GITHUB_ORG="${GITHUB_ORG:-$(git -C "$PROJECT_ROOT" remote get-url origin | sed -E 's#.*github.com[:/]##; s#/.*##')}"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI is required"; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform >= 1.10 is required"; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI is required (sets repo variables)"; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# Make the region explicit for every AWS CLI call in this script.
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
echo ">> Bootstrapping healthcare-ai platform"
echo "   AWS account : $ACCOUNT_ID"
echo "   Region      : $REGION"
echo "   GitHub repo : $GITHUB_ORG/$GITHUB_REPO"

# ── 1. KMS key + alias for state encryption ─────────────────────────────────
if ! aws kms describe-key --key-id "$KMS_ALIAS" >/dev/null 2>&1; then
  echo ">> Creating KMS key + alias $KMS_ALIAS"
  KEY_ARN="$(aws kms create-key --description "healthcare-ai terraform state encryption" \
    --query KeyMetadata.Arn --output text)"
  aws kms create-alias --alias-name "$KMS_ALIAS" --target-key-id "$KEY_ARN"
else
  echo ">> KMS alias $KMS_ALIAS already exists"
fi

# ── 2. S3 state bucket (must exist before terraform init) ────────────────────
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo ">> Creating S3 state bucket $BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
else
  echo ">> S3 state bucket $BUCKET already exists"
fi

# use_lockfile requires versioning enabled
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KMS_ALIAS\"}}]}"

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# ── 3. Terraform apply ────────────────────────────────────────────────────────
echo ">> terraform init + apply"
cd "$PROJECT_ROOT/infrastructure/terraform"
terraform init
terraform apply -auto-approve \
  -var="aws_account_id=$ACCOUNT_ID" \
  -var="github_org=$GITHUB_ORG" \
  -var="github_repo=$GITHUB_REPO"

DEPLOYER_ARN="$(terraform output -raw terraform_deployer_role_arn)"
PLANNER_ARN="$(terraform output -raw terraform_planner_role_arn)"
ECR_URL="$(terraform output -raw ecr_repository_url)"

# ── 4. Wire GitHub Actions repository variables ──────────────────────────────
echo ">> Setting GitHub Actions repository variables"
REPO="$GITHUB_ORG/$GITHUB_REPO"
gh variable set AWS_ROLE_TO_ASSUME   --body "$DEPLOYER_ARN" -R "$REPO"
gh variable set AWS_PLANNER_ROLE_ARN --body "$PLANNER_ARN"  -R "$REPO"
gh variable set AWS_ACCOUNT_ID       --body "$ACCOUNT_ID"  -R "$REPO"
gh variable set GITHUB_ORG           --body "$GITHUB_ORG"  -R "$REPO"
if [ -n "${ARGOCD_SERVER:-}" ]; then
  gh variable set ARGOCD_SERVER --body "$ARGOCD_SERVER" -R "$REPO"
else
  echo "   (skipped ARGOCD_SERVER — set it later: gh variable set ARGOCD_SERVER --body <url> -R $REPO)"
fi

# ── 5. Point the ArgoCD Application at the real ECR registry ─────────────────
ARGOCD_APP="$PROJECT_ROOT/kubernetes/argocd/java-healthcare-app.yaml"
if grep -q "REPLACE_ECR_REGISTRY" "$ARGOCD_APP"; then
  sed -i.bak "s|REPLACE_ECR_REGISTRY/healthcare-ai/java-healthcare-app|$ECR_URL|" "$ARGOCD_APP"
  echo ">> Patched $ARGOCD_APP with ECR image: $ECR_URL"
  echo "   Commit this change so ArgoCD picks it up from git."
fi

# ── 6. Map the deployer role into the cluster (aws-auth) ─────────────────────
# AWS authentication alone does not grant Kubernetes access: GitHub-hosted
# runners (kubectl/argocd) need the deployer role mapped in the aws-auth
# ConfigMap. The EKS API endpoint is public for this PoC (see modules/eks).
echo ">> Mapping deployer role into EKS aws-auth ConfigMap"
aws eks update-kubeconfig --name "$(terraform output -raw eks_cluster_name)" --region "$REGION"
kubectl -n kube-system patch configmap aws-auth --type merge -p \
  '{"data":{"mapRoles":"- rolearn: '"$DEPLOYER_ARN"'\n  username: github-actions\n  groups:\n  - system:masters\n"}}'

# ── 7. Optional: seed an ArgoCD admin password in Secrets Manager ─────────────
# NOTE: this stores the credential the ArgoCD CLI jobs use; it does NOT by itself
# reconfigure a running ArgoCD instance — align it during `make k8s` (Ansible).
if [ "${SEED_ARGOCD_PASSWORD:-}" = "1" ]; then
  PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' )"
  aws secretsmanager put-secret-value \
    --secret-id /healthcare-ai/argocd/admin \
    --secret-string "{\"username\":\"admin\",\"password\":\"$PASSWORD\"}"
  echo ">> ArgoCD admin password seeded in Secrets Manager (path: /healthcare-ai/argocd/admin)"
fi

echo ""
echo ">> Bootstrap complete."
echo "   Next: make serverless && bash scripts/terraform-to-ansible.sh && make k8s"
echo "   Then:   bash scripts/apply-gitops.sh   # registers the ArgoCD Applications"
echo "   Then push to main — the CI/CD pipeline now runs fully keyless."
