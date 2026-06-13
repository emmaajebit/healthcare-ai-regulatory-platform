# Healthcare AI Regulatory Platform

A production-grade, HIPAA/FDA-compliant DevSecOps platform for deploying AI-powered healthcare applications on AWS. Built with immutable infrastructure, RAG-enhanced AI validation, supply-chain security (SLSA + Cosign), WORM audit trails, and **keyless OIDC authentication** — no long-lived AWS credentials anywhere.

---

## Architecture Overview

```
Developer Push
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│              GitHub Actions CI/CD (10 stages)                   │
│                                                                 │
│  ┌──────────────┐   OIDC token exchange (no static keys)        │
│  │ aws-actions/ │──────────────────────────────────────────►    │
│  │ configure-   │        AWS STS (AssumeRoleWithWebIdentity)     │
│  │ aws-creds    │◄──────────────────────────────────────────     │
│  └──────────────┘   Temporary credentials (15-min TTL)         │
│                                                                 │
│  Build → RAG AI Validate → Trivy → Checkov → SLSA →            │
│  Cosign Sign → Push ECR → Terraform Apply → ArgoCD Deploy →     │
│  k6 Test → WORM Audit                                          │
└─────────────────────────────────────────────────────────────────┘
      │                              │
      ▼                              ▼
┌──────────────┐            ┌─────────────────────┐
│  AWS Bedrock │            │   Amazon EKS         │
│  (Claude 3)  │            │  ┌───────────────┐  │
│  + OpenSearch│            │  │  Kyverno      │  │
│  Serverless  │            │  │  (SLSA+Cosign │  │
│  (RAG rules) │            │  │   enforce)    │  │
└──────────────┘            │  ├───────────────┤  │
                            │  │  ArgoCD GitOps│  │
┌──────────────┐            │  ├───────────────┤  │
│  S3 WORM     │            │  │  Java App     │  │
│  (6yr retain)│            │  │  (Helm chart) │  │
│  + DynamoDB  │            │  └───────────────┘  │
│  Audit Log   │            └─────────────────────┘
└──────────────┘
┌──────────────┐
│  S3 State    │  ← Terraform 1.10 native locking (use_lockfile)
│  + .tflock   │    No DynamoDB required for state locking
└──────────────┘
┌──────────────┐
│  AWS Secrets │  ← ArgoCD, Helm token, JWT key, API keys
│  Manager     │    KMS-encrypted, fetched at runtime by Ansible
└──────────────┘
```

---

## Key Features

| Feature | Technology | Purpose |
|---------|-----------|---------|
| **Keyless Auth (OIDC)** | GitHub OIDC + AWS STS | GitHub Actions exchanges OIDC tokens for 15-min credentials — no static AWS keys stored anywhere |
| **S3 Native State Locking** | Terraform 1.10 `use_lockfile` | Concurrent-safe state locking via S3 conditional writes — DynamoDB lock table eliminated |
| RAG AI Validation | AWS Bedrock (Claude 3) + OpenSearch Serverless | Validates code changes against HIPAA/FDA rules before deployment |
| Supply Chain Security | SLSA v1.0 + Cosign | Tamper-proof build provenance and image signing |
| Policy Enforcement | Kyverno | Blocks unsigned/unattested images at the cluster gate |
| WORM Audit Trail | S3 Object Lock (COMPLIANCE mode) + DynamoDB | Immutable 6-year audit records for HIPAA/FDA auditors |
| Secrets Management | AWS Secrets Manager + KMS CMK | All secrets KMS-encrypted; Ansible fetches values at runtime via ARN — nothing plaintext in git |
| Ephemeral Environments | GitHub Actions + Kubernetes namespaces | Isolated preview environments per pull request |
| Zero-Trust Networking | Kubernetes NetworkPolicy (default-deny) | No lateral movement between workloads |
| Ansible Bridge | `terraform-to-ansible.sh` | Converts `terraform output` into Ansible inventory + group_vars automatically |

---

## Prerequisites

- AWS account with admin permissions (for initial bootstrap only)
- Git, Bash
- **Terraform ≥ 1.10** (required for `use_lockfile` S3 native locking)
- All other tools installed automatically by the bootstrap script below

---

## Quick Start

### Step 1 — Clone and bootstrap the toolchain

```bash
git clone https://github.com/emmaajebit/healthcare-ai-regulatory-platform.git
cd healthcare-ai-regulatory-platform

# Installs: Terraform 1.10, AWS CLI v2, kubectl, Helm, eksctl,
#           Ansible, ArgoCD CLI, cosign, k6, yq, checkov
# Writes /tmp/tool-versions.json for Ansible consumption
sudo bash scripts/install-devops-tools.sh
```

### Step 2 — Configure AWS (local bootstrap only)

> **Note:** Local AWS credentials are only needed for the one-time bootstrap below.
> After OIDC roles are created, GitHub Actions authenticates keylessly — no secrets needed.

```bash
aws configure
# Enter: Access Key ID, Secret Access Key, region (us-east-1), output (json)
```

### Step 3 — Create the Terraform state bucket

S3 native locking (`use_lockfile = true`) requires the bucket to have **versioning enabled**.
No DynamoDB table needed.

```bash
aws s3api create-bucket \
  --bucket healthcare-ai-terraform-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket healthcare-ai-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket healthcare-ai-terraform-state \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "alias/healthcare-ai-terraform-state"
      }
    }]
  }'
```

> **What changed:** The old setup required a DynamoDB table (`healthcare-ai-terraform-locks`) for state locking.
> Terraform 1.10 replaces this with a `<key>.tflock` object written directly to S3 using conditional
> `PutObject` — no DynamoDB table needed at all.

### Step 4 — Provision AWS infrastructure

```bash
cd infrastructure/terraform
terraform init

terraform apply \
  -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)" \
  -var="github_org=emmaajebit"

# Provisions: VPC, EKS, ECR, OpenSearch Serverless,
#             S3 WORM bucket, DynamoDB audit log,
#             GitHub OIDC provider, IAM deployer/planner roles,
#             Secrets Manager secrets (ArgoCD, app secrets, Helm token)
```

### Step 5 — Wire up GitHub Actions OIDC (one-time)

After `terraform apply`, grab the deployer role ARN:

```bash
terraform output terraform_deployer_role_arn
# → arn:aws:iam::123456789012:role/healthcare-ai-terraform-deployer
```

Add **one** repository variable (not secret) to GitHub (`Settings → Secrets and variables → Actions → Variables`):

| Variable | Value |
|----------|-------|
| `AWS_ROLE_TO_ASSUME` | ARN from the command above |

In your GitHub Actions workflow:

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ vars.AWS_ROLE_TO_ASSUME }}
    aws-region: us-east-1
```

> **No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` needed.** GitHub exchanges an OIDC token
> for 15-minute temporary credentials. The deployer role only trusts pushes to `main`;
> the planner role trusts any branch for `terraform plan`.

### Step 6 — Deploy serverless AI stack

```bash
make serverless
# Deploys: Bedrock Validator Lambda, Compliance Aggregator Lambda
```

### Step 7 — Sync Terraform outputs to Ansible

```bash
bash scripts/terraform-to-ansible.sh
# Reads: terraform output -json
# Writes: ansible/inventory/hosts.yml
#         ansible/playbooks/group_vars/all.yml
# Secret values are NOT written — only Secrets Manager ARNs are stored
```

### Step 8 — Deploy Kubernetes add-ons

```bash
# Ansible fetches secrets from AWS Secrets Manager at runtime
# No ansible-vault encryption needed for secrets — they live in Secrets Manager
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/deploy-eks-addons.yml

# Deploys: Kyverno, ArgoCD, Secrets Store CSI, Prometheus/Grafana
```

### Step 9 — Populate secrets in AWS Secrets Manager

Terraform seeds placeholder values. Replace them via CLI (or AWS Console):

```bash
# ArgoCD admin password
aws secretsmanager put-secret-value \
  --secret-id /healthcare-ai/argocd/admin \
  --secret-string '{"username":"admin","password":"<your-strong-password>"}'

# Application secrets (JWT key, API keys)
aws secretsmanager put-secret-value \
  --secret-id /healthcare-ai/app/secrets \
  --secret-string '{"jwt_signing_key":"<key>","bedrock_api_key":"<key>","openai_api_key":"<key>"}'

# Helm repo token
aws secretsmanager put-secret-value \
  --secret-id /healthcare-ai/helm/repo-token \
  --secret-string '{"username":"<user>","token":"<token>"}'
```

Ansible playbooks retrieve these values at runtime using `community.aws.aws_secret` — the values are never written to disk or git.

### Step 10 — Seed RAG compliance rules

```bash
make seed-rag
# Loads HIPAA/FDA rules into OpenSearch for AI-assisted validation
```

### Step 11 — Push code to trigger the pipeline

```bash
git push origin main
# Triggers the 10-stage CI/CD pipeline automatically
# GitHub Actions authenticates to AWS via OIDC — no static credentials
```

---

## Project Structure

```
healthcare-ai-regulatory-platform/
├── .github/workflows/
│   ├── cicd-pipeline.yml            # 10-stage main pipeline
│   └── pr-ephemeral.yml             # Per-PR isolated preview environments
├── scripts/
│   ├── install-devops-tools.sh      # One-click toolchain installer (Terraform 1.10,
│   │                                #   AWS CLI v2, kubectl, Helm, eksctl, Ansible,
│   │                                #   ArgoCD, cosign, k6, yq, checkov)
│   │                                #   Emits /tmp/tool-versions.json for Ansible
│   ├── terraform-to-ansible.sh      # Converts terraform output → hosts.yml + group_vars
│   ├── generate-audit-proof.sh      # HIPAA/FDA audit report generator
│   └── seed-compliance-rules.py     # RAG database seeder
├── infrastructure/
│   ├── terraform/
│   │   ├── tvars.tf                 # All variable declarations (single source of truth)
│   │   ├── main.tf                  # Provider (OIDC-aware), modules, WORM bucket, audit log
│   │   ├── backend.tf               # S3 backend with use_lockfile = true (Terraform 1.10)
│   │   ├── oidc.tf                  # GitHub OIDC provider + deployer/planner IAM roles
│   │   ├── secrets.tf               # Secrets Manager secrets + KMS CMK + IRSA reader policy
│   │   ├── outputs.tf               # Structured outputs consumed by terraform-to-ansible.sh
│   │   └── modules/
│   │       ├── vpc/                 # VPC, subnets, NAT gateways
│   │       ├── eks/                 # EKS cluster + managed node group + IAM roles
│   │       ├── ecr/                 # ECR repository with KMS + lifecycle policy
│   │       └── opensearch_serverless/ # OpenSearch collection for RAG
│   └── sam/
│       ├── src/bedrock_validator/   # Lambda: AI code validation against HIPAA/FDA rules
│       └── src/compliance_aggregator/ # Lambda: compliance status aggregation
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.yml                # Auto-generated by terraform-to-ansible.sh
│   └── playbooks/
│       ├── deploy-eks-addons.yml    # Kyverno, ArgoCD, CSI, Prometheus/Grafana
│       └── group_vars/
│           └── all.yml              # Secrets Manager ARNs only — no plaintext secrets
└── kubernetes/
    ├── argocd/                      # App-of-Apps GitOps bootstrapping
    ├── kyverno/policies/            # SLSA, Cosign, and security baseline enforcement
    ├── network-policies/            # Zero-trust default-deny
    └── helm/java-healthcare-app     # Application Helm chart
```

---

## Authentication Model

```
Local development     →  aws configure  (one-time bootstrap only)
GitHub Actions apply  →  OIDC token  →  sts:AssumeRoleWithWebIdentity  →  Deployer role (main branch)
GitHub Actions plan   →  OIDC token  →  sts:AssumeRoleWithWebIdentity  →  Planner role  (any branch)
EKS pods              →  IRSA        →  secrets-reader policy           →  Secrets Manager
```

No static AWS keys are stored in GitHub Secrets, `.env` files, or CI environment variables.

---

## State Locking (Terraform 1.10)

```
terraform apply
    │
    ├─► PUT s3://healthcare-ai-terraform-state/global/terraform.tfstate.tflock
    │       (If-None-Match: * — fails if lock already exists)
    │
    ├─► ... apply runs ...
    │
    └─► DELETE s3://...terraform.tfstate.tflock
```

If a lock exists when a second `apply` starts, Terraform returns `ConditionalRequestConflict` and aborts — exactly the same behaviour as DynamoDB locking but without the extra AWS resource.

---

## Generating an Audit Report

```bash
make audit-report
# Collects SLSA provenance, AI validation logs, and scan results
# Packages and stores them in the S3 WORM bucket for auditors
```

---

## Teardown

```bash
make destroy
# Destroys all Terraform-managed AWS infrastructure
```

> **Warning:** The S3 WORM bucket cannot be deleted until the retention period expires
> (COMPLIANCE mode, 6 years). This is intentional for HIPAA compliance.

---

## Author

Emmanuel Ajebit
