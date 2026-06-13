# Healthcare AI Regulatory Platform

A production-grade, HIPAA/FDA-compliant DevSecOps platform for deploying AI-powered healthcare applications on AWS. Built with immutable infrastructure, RAG-enhanced AI validation, supply-chain security (SLSA + Cosign), and WORM audit trails.

---

## Architecture Overview

```
Developer Push
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│                  GitHub Actions CI/CD (10 stages)           │
│  Build → RAG AI Validate → Trivy → Checkov → SLSA →        │
│  Cosign Sign → Push ECR → ArgoCD Deploy → k6 Test → WORM   │
└─────────────────────────────────────────────────────────────┘
      │                          │
      ▼                          ▼
┌──────────────┐        ┌─────────────────────┐
│  AWS Bedrock │        │   Amazon EKS         │
│  (Claude 3)  │        │  ┌───────────────┐  │
│  + OpenSearch│        │  │  Kyverno      │  │
│  Serverless  │        │  │  (SLSA+Cosign │  │
│  (RAG rules) │        │  │   enforce)    │  │
└──────────────┘        │  ├───────────────┤  │
                        │  │  ArgoCD GitOps│  │
┌──────────────┐        │  ├───────────────┤  │
│  S3 WORM     │        │  │  Java App     │  │
│  (6yr retain)│        │  │  (Helm chart) │  │
│  + DynamoDB  │        │  └───────────────┘  │
│  Audit Log   │        └─────────────────────┘
└──────────────┘
```

---

## Key Features

| Feature | Technology | Purpose |
|---------|-----------|---------|
| RAG AI Validation | AWS Bedrock (Claude 3) + OpenSearch Serverless | Validates code changes against HIPAA/FDA rules before deployment |
| Supply Chain Security | SLSA v1.0 + Cosign | Tamper-proof build provenance and image signing |
| Policy Enforcement | Kyverno | Blocks unsigned/unattested images at the cluster gate |
| WORM Audit Trail | S3 Object Lock (COMPLIANCE mode) + DynamoDB | Immutable 6-year audit records for HIPAA/FDA auditors |
| Ephemeral Environments | GitHub Actions + Kubernetes namespaces | Isolated preview environments per pull request |
| Secrets Management | AWS Secrets Manager + CSI Driver | Zero plaintext secrets in pods |
| Zero-Trust Networking | Kubernetes NetworkPolicy (default-deny) | No lateral movement between workloads |

---

## Prerequisites

- AWS account with admin permissions
- Tools: `terraform`, `ansible`, `kubectl`, `helm`, `cosign`, `k6`, `aws-sam-cli`
- Run `make bootstrap` to install all tools automatically

---

## Quick Start

### Step 1 — Bootstrap the toolchain

```bash
git clone https://github.com/emmaajebit/healthcare-ai-regulatory-platform.git
cd healthcare-ai-regulatory-platform
make bootstrap
```

### Step 2 — Configure AWS credentials

```bash
aws configure
# Enter: AWS Access Key ID, Secret Access Key, region (us-east-1), output (json)
```

### Step 3 — Create Terraform remote state bucket

```bash
aws s3api create-bucket \
  --bucket healthcare-ai-terraform-state \
  --region us-east-1

aws dynamodb create-table \
  --table-name healthcare-ai-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### Step 4 — Provision AWS infrastructure

```bash
make infra
# Provisions: VPC, EKS, ECR, OpenSearch Serverless, S3 WORM bucket, DynamoDB audit table
```

### Step 5 — Deploy serverless AI stack

```bash
make serverless
# Deploys: Bedrock Validator Lambda, Compliance Aggregator Lambda
```

### Step 6 — Deploy Kubernetes add-ons

```bash
# Encrypt the Ansible vars first
ansible-vault encrypt ansible/playbooks/group_vars/all.yml

# Deploy Kyverno, ArgoCD, Secrets Store CSI, Prometheus/Grafana
make k8s
```

### Step 7 — Seed RAG compliance rules

```bash
make seed-rag
# Loads HIPAA/FDA rules into OpenSearch for AI-assisted validation
```

### Step 8 — Configure GitHub Secrets

Add these secrets to your GitHub repository (`Settings → Secrets → Actions`):

| Secret | Value |
|--------|-------|
| `ECR_REGISTRY` | Output from `terraform output ecr_repository_url` |
| `ARGOCD_SERVER` | Your ArgoCD server URL |
| `ARGOCD_TOKEN` | ArgoCD API token |
| `COSIGN_PRIVATE_KEY` | Contents of your `cosign.key` file |
| `AWS_ACCESS_KEY_ID` | AWS credentials for CI |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials for CI |

### Step 9 — Push code to trigger the pipeline

```bash
git push origin main
# Triggers the 10-stage CI/CD pipeline automatically
```

---

## Project Structure

```
healthcare-ai-regulatory-platform/
├── .github/workflows/
│   ├── cicd-pipeline.yml        # 10-stage main pipeline
│   └── pr-ephemeral.yml         # Per-PR isolated preview environments
├── scripts/
│   ├── install-devops-tools.sh  # Idempotent toolchain installer
│   ├── generate-audit-proof.sh  # HIPAA/FDA audit report generator
│   └── seed-compliance-rules.py # RAG database seeder
├── infrastructure/
│   ├── terraform/               # VPC, EKS, ECR, OpenSearch, S3 WORM, DynamoDB
│   └── sam/                     # Bedrock Validator + Compliance Aggregator Lambdas
├── kubernetes/
│   ├── argocd/                  # App-of-Apps GitOps bootstrapping
│   ├── kyverno/policies/        # SLSA, Cosign, and security baseline enforcement
│   ├── network-policies/        # Zero-trust default-deny
│   └── helm/java-healthcare-app # Application Helm chart
└── ansible/
    ├── ansible.cfg
    ├── inventory/
    └── playbooks/               # EKS add-on deployment playbook
```

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

> **Warning:** The S3 WORM bucket cannot be deleted until the retention period expires (COMPLIANCE mode). This is intentional for HIPAA compliance.

---

## Author

Emmanuel Ajebit
