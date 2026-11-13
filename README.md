# Healthcare AI Regulatory Platform

A production-grade, HIPAA/FDA-compliant DevSecOps platform for deploying AI-powered healthcare applications on AWS. Built with immutable infrastructure, RAG-enhanced AI validation, **Cosign keyless signing + SLSA v1.0 provenance**, WORM audit trails, and **keyless OIDC authentication** — no long-lived AWS credentials and no private signing keys stored anywhere.

---

## Architecture Overview

```
Developer Push
      │
      ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  GitHub Actions CI/CD Pipeline                       │
│                                                                      │
│  ┌─────────────┐  OIDC token ──► AWS STS (AssumeRoleWithWebIdentity) │
│  │  Every job  │  OIDC token ──► Sigstore Fulcio (cosign sign)       │
│  │  (no keys)  │  Temp creds ◄── STS  (15-min TTL)                  │
│  └─────────────┘                                                     │
│                                                                      │
│  Stage 1 ── Build + Push to ECR  (outputs sha256 digest)            │
│                    │                                                 │
│       ┌────────────┼────────────┐                                    │
│       ▼            ▼            ▼                                    │
│  Stage 2        Stage 3     Stage 4                                  │
│  RAG AI         Trivy        Checkov                                 │
│  Validate       Scan         IaC Scan                                │
│       └────────────┼────────────┘                                    │
│                    ▼                                                 │
│  Stage 5 ── SLSA v1.0 Provenance                                    │
│              actions/attest-build-provenance@v1                      │
│              → GitHub attestation store                              │
│              → OCI registry (push-to-registry: true)                │
│                    │                                                 │
│                    ▼                                                 │
│  Stage 6 ── Cosign Keyless Sign + Attest + Verify                   │
│              cosign sign   → Sigstore Fulcio cert → Rekor log        │
│              cosign attest → SLSA predicate → Rekor log              │
│              cosign verify → gate (fail if invalid)                  │
│                    │                                                 │
│                    ▼                                                 │
│  Stage 8 ── ArgoCD GitOps Sync                                      │
│  Stage 9 ── k6 Load Test                                            │
│  Stage 10 ─ WORM Compliance Report                                  │
└──────────────────────────────────────────────────────────────────────┘
      │                                    │
      ▼                                    ▼
┌──────────────┐                  ┌─────────────────────┐
│  AWS Bedrock │                  │   Amazon EKS         │
│  (Claude 3)  │                  │  ┌───────────────┐  │
│  + OpenSearch│                  │  │  Kyverno      │  │
│  Serverless  │                  │  │  enforce:     │  │
│  (RAG rules) │                  │  │  • cosign sig │  │
└──────────────┘                  │  │  • SLSA attest│  │
                                  │  ├───────────────┤  │
┌──────────────┐                  │  │  ArgoCD GitOps│  │
│  S3 WORM     │                  │  ├───────────────┤  │
│  (6yr retain)│                  │  │  Java App     │  │
│  + DynamoDB  │                  │  │  (Helm chart) │  │
│  Audit Log   │                  │  └───────────────┘  │
└──────────────┘                  └─────────────────────┘
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
| **Keyless AWS Auth (OIDC)** | GitHub OIDC + AWS STS | GitHub Actions exchanges OIDC tokens for 15-min STS credentials — no static AWS keys stored anywhere |
| **Cosign Keyless Signing** | Sigstore Cosign + Fulcio + Rekor | Image signed with a short-lived cert issued against the GitHub OIDC identity — no private key files or KMS keys required |
| **SLSA v1.0 Provenance** | `actions/attest-build-provenance` + `cosign attest` | Tamper-proof build provenance stored in GitHub attestation store and OCI registry via Sigstore; verified at Kyverno admission gate |
| **S3 Native State Locking** | Terraform 1.10 `use_lockfile` | Concurrent-safe state locking via S3 conditional writes — DynamoDB lock table eliminated |
| RAG AI Validation | AWS Bedrock (Claude 3) + OpenSearch Serverless | Validates code changes against HIPAA/FDA rules before deployment |
| Policy Enforcement | Kyverno (keyless attestors) | Rejects any pod image that lacks a valid Cosign signature **and** SLSA attestation from `cicd-pipeline.yml@main` |
| WORM Audit Trail | S3 Object Lock (COMPLIANCE mode) + DynamoDB | Immutable 6-year audit records for HIPAA/FDA auditors |
| Secrets Management | AWS Secrets Manager + KMS CMK | All secrets KMS-encrypted; Ansible and pods fetch values at runtime via ARN — nothing plaintext in git |
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

### Demo in one command

The fastest path for a demo — bootstraps AWS, applies Terraform, and wires up
GitHub Actions keyless auth in one shot (requires admin AWS credentials locally):

```bash
bash scripts/bootstrap-aws.sh            # + optional: ARGOCD_SERVER=argocd.example:443 SEED_SECRETS=1
make secrets                             # real ArgoCD (+bcrypt), Grafana, JWT, API keys — BEFORE k8s
make serverless                          # Bedrock validator + compliance aggregator Lambdas
make k8s                                 # syncs TF outputs → Ansible, installs Kyverno (Audit), ArgoCD, CSI, Prometheus
make k8s-enforce                         # once the signed image is admitted cleanly: Kyverno → Enforce
```

After that, every push to `main` runs the full 10-stage keyless pipeline
(build → RAG validation → Trivy → Checkov → SLSA → Cosign → ArgoCD → k6 → WORM report),
and every infrastructure change runs fmt/validate/plan/apply through the
`Terraform` workflow's OIDC roles.

Until the one-time bootstrap runs (and sets the `AWS_*` repository variables),
the AWS-dependent pipeline stages are **skipped, not failed** — credential-free
checks (fmt, validate, Checkov) still run green on every push.

> PoC tradeoffs, documented inline in the code: the EKS API endpoint is public
> so GitHub-hosted runners can reach it — narrow it with `eks_public_access_cidrs`,
> or for production set `eks_endpoint_public_access=false`, run Ansible from an
> SSM bastion in the VPC, and point the `DEPLOY_RUNNER` repo variable at a
> self-hosted runner in the VPC. The deployer role gets cluster access through an
> EKS access entry and has AdministratorAccess in AWS, and a handful of
> Checkov checks are skipped in `infrastructure/terraform/.checkov.yml`.
> The WORM bucket's Object Lock compliance retention also prevents deleting
> the audit objects before `worm_retention_days` — plan cleanup accordingly.

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
# Preferred: short-lived credentials via IAM Identity Center
aws configure sso && aws sso login

# Fallback: `aws configure` with temporary admin keys — delete the access key
# in IAM as soon as bootstrap is done (CI never needs it).
```

### Step 3 — Create the Terraform state bucket

S3 native locking (`use_lockfile = true`) requires **versioning enabled** on the bucket.
No DynamoDB table is needed. `scripts/bootstrap-aws.sh` does all of this idempotently
(KMS key with rotation, versioning, SSE-KMS, public-access block). Manual equivalent:

```bash
KEY_ID=$(aws kms create-key --description "healthcare-ai terraform state" --query KeyMetadata.KeyId --output text)
aws kms enable-key-rotation --key-id "$KEY_ID"
aws kms create-alias --alias-name alias/healthcare-ai-terraform-state --target-key-id "$KEY_ID"

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

aws s3api put-public-access-block \
  --bucket healthcare-ai-terraform-state \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### Step 4 — Provision AWS infrastructure

```bash
cd infrastructure/terraform
terraform init

terraform apply \
  -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)" \
  -var="github_org=emmaajebit" \
  -var='eks_public_access_cidrs=["<your-ip>/32"]'   # omit only if CI uses GitHub-hosted runners

# Provisions: VPC, EKS, ECR, OpenSearch Serverless,
#             S3 WORM bucket, DynamoDB audit log,
#             GitHub OIDC provider, IAM deployer/planner roles,
#             Secrets Manager secrets (ArgoCD, app secrets, Helm token)
```

### Step 5 — Wire up GitHub Actions (one-time)

After `terraform apply`, set these **repository variables** (not secrets) in GitHub
(`Settings → Secrets and variables → Actions → Variables`):

```bash
terraform output terraform_deployer_role_arn
# → arn:aws:iam::123456789012:role/healthcare-ai-terraform-deployer
```

| Variable | Value |
|----------|-------|
| `AWS_ROLE_TO_ASSUME` | ARN from `terraform output terraform_deployer_role_arn` |
| `ARGOCD_SERVER` | Your ArgoCD server URL (e.g. `argocd.internal:443`) |
| `DEPLOY_RUNNER` | *(optional)* label of a self-hosted runner inside the VPC for the ArgoCD + k6 jobs (needed with a private EKS endpoint) |

> **No `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or `COSIGN_PRIVATE_KEY` needed.**
> GitHub exchanges an OIDC token for both AWS STS credentials and a Sigstore Fulcio
> certificate — all scoped to the current workflow run.

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

### Step 8 — Populate secrets in AWS Secrets Manager (before Ansible)

Terraform seeds placeholders; the playbook refuses to run until they are real.

```bash
make secrets        # = bash scripts/populate-secrets.sh
# ArgoCD : random password + precomputed bcrypt hash (password_bcrypt)
# Grafana: its own random password (never shared with ArgoCD)
# App    : random JWT key; Bedrock/OpenAI keys prompted silently
# Values go through a 0600 temp file — nothing in argv or shell history.
```

### Step 9 — Deploy Kubernetes add-ons

The EKS API must be reachable from where you run this (your IP in
`eks_public_access_cidrs`, or an SSM bastion inside the VPC).

```bash
ansible-galaxy collection install kubernetes.core amazon.aws
pip install boto3 botocore kubernetes

make k8s-check      # dry run (--check --diff)
make k8s            # Kyverno policies start in **Audit** mode

kubectl get policyreport -A    # confirm the pipeline-signed image passes
make k8s-enforce               # then flip Kyverno to Enforce

# Deploys: Kyverno (keyless Cosign + SLSA + baseline policies),
#          ArgoCD, Secrets Store CSI + AWS provider, Prometheus/Grafana
```

### Step 10 — Seed RAG compliance rules

```bash
make seed-rag
# Loads HIPAA/FDA rules into OpenSearch for AI-assisted validation
```

### Step 11 — Push code to trigger the pipeline

```bash
git status          # make sure no .terraform/, *.tfvars or local outputs are staged
git push origin main
# Triggers the full CI/CD pipeline — OIDC auth, SLSA, Cosign keyless sign, ArgoCD deploy
```

---

## Supply Chain Security (Cosign + SLSA)

### How keyless Cosign signing works

No private keys are stored anywhere. For each pipeline run on `main`:

```
GitHub Actions runner
    │
    ├─► GitHub OIDC endpoint  →  short-lived OIDC JWT
    │                               (sub: repo/.../cicd-pipeline.yml@refs/heads/main)
    │
    ├─► Sigstore Fulcio CA   →  short-lived X.509 cert  (10-min TTL)
    │
    ├─► cosign sign <image>@<digest>
    │       Signs the image digest with the ephemeral key
    │       Uploads signature + cert to Rekor transparency log
    │
    └─► cosign verify  (pipeline gate — fails if invalid)
```

The signature certificate is publicly auditable in Rekor. Anyone can verify it without access to AWS or GitHub.

### How SLSA provenance is generated

Two complementary provenance artifacts are produced per build:

| Artifact | Tool | Where stored | Format |
|----------|------|-------------|--------|
| GitHub-native provenance | `actions/attest-build-provenance@v1` | GitHub attestation store + OCI registry | SLSA v1.0 Build L1+ |
| Cosign OCI attestation | `cosign attest --type slsaprovenance1` | OCI registry + Rekor | SLSA v1.0 predicate |

### Verifying a released image

```bash
IMAGE="<ecr-account>.dkr.ecr.us-east-1.amazonaws.com/java-healthcare-app"
DIGEST="sha256:<digest>"

# Verify Cosign keyless signature
cosign verify \
  --certificate-identity-regexp \
    "https://github.com/emmaajebit/healthcare-ai-regulatory-platform/.github/workflows/cicd-pipeline.yml@.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "${IMAGE}@${DIGEST}"

# Verify GitHub SLSA attestation
gh attestation verify "oci://${IMAGE}@${DIGEST}" \
  --repo emmaajebit/healthcare-ai-regulatory-platform

# Verify Cosign SLSA attestation (OCI registry)
cosign verify-attestation \
  --type slsaprovenance1 \
  --certificate-identity-regexp \
    "https://github.com/emmaajebit/healthcare-ai-regulatory-platform/.github/workflows/cicd-pipeline.yml@.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "${IMAGE}@${DIGEST}"
```

### Kyverno admission gate

`ClusterPolicy` resources in `kubernetes/kyverno/policies/` enforce these checks at pod admission
(installed in Audit mode first, then switched with `make k8s-enforce`; they apply to the
`default`, `healthcare`, `staging` and `production` namespaces — platform namespaces are excluded):

| Policy | What it checks |
|--------|---------------|
| `enforce-image-signature` | Cosign keyless signature present, cert issued by GitHub OIDC, recorded in Rekor |
| `enforce-slsa-provenance` | SLSA v1.0 attestation present, same keyless identity, `buildType` and `repository` match this repo |
| `enforce-security-baseline` | non-root, read-only root FS, no privilege escalation, capabilities dropped, CPU/memory limits |

Any pod that references an image without both artifacts is **rejected before scheduling**.

---

## Authentication Model

```
Local bootstrap       →  aws sso login  (one-time only, short-lived)
GitHub Actions apply  →  OIDC token  →  sts:AssumeRoleWithWebIdentity  →  Deployer role (main)
GitHub Actions plan   →  OIDC token  →  sts:AssumeRoleWithWebIdentity  →  Planner role  (any branch)
Cosign signing        →  OIDC token  →  Sigstore Fulcio cert  →  Rekor transparency log
EKS pods              →  IRSA        →  secrets-reader policy  →  Secrets Manager
```

No static AWS keys, no Cosign private keys, no tokens in GitHub Secrets.

---

## State Locking (Terraform 1.10)

```
terraform apply
    │
    ├─► PUT s3://healthcare-ai-terraform-state/global/terraform.tfstate.tflock
    │       (If-None-Match: * — atomic, fails if lock already exists)
    │
    ├─► ... apply runs ...
    │
    └─► DELETE s3://...terraform.tfstate.tflock
```

If a concurrent `apply` finds the lock file already present, Terraform returns `ConditionalRequestConflict` and aborts — same behaviour as DynamoDB locking, zero extra AWS resources.

---

## Project Structure

```
healthcare-ai-regulatory-platform/
├── .github/workflows/
│   ├── cicd-pipeline.yml            # 10-stage main pipeline (OIDC, SLSA, Cosign keyless)
│   └── pr-ephemeral.yml             # Per-PR preview environments (OIDC auth)
├── scripts/
│   ├── install-devops-tools.sh      # One-click toolchain installer
│   │                                #   Terraform 1.10 · AWS CLI v2 · kubectl · Helm
│   │                                #   eksctl · Ansible · ArgoCD · cosign · k6 · yq · checkov
│   │                                #   Emits /tmp/tool-versions.json for Ansible
│   ├── terraform-to-ansible.sh      # terraform output -json → hosts.yml + group_vars
│   ├── generate-audit-proof.sh      # HIPAA/FDA audit report generator
│   └── seed-compliance-rules.py     # RAG database seeder
├── infrastructure/
│   ├── terraform/
│   │   ├── tvars.tf                 # All variable declarations (single source of truth)
│   │   ├── main.tf                  # Provider (OIDC-aware), modules, WORM bucket, audit log
│   │   ├── backend.tf               # S3 backend — use_lockfile = true (Terraform 1.10)
│   │   ├── oidc.tf                  # GitHub OIDC provider + deployer/planner IAM roles
│   │   ├── secrets.tf               # Secrets Manager + KMS CMK + IRSA reader policy
│   │   ├── outputs.tf               # Outputs consumed by terraform-to-ansible.sh
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
    ├── kyverno/policies/
    │   ├── enforce-image-signature.yaml   # Cosign keyless signature (Fulcio + Rekor)
    │   ├── enforce-slsa-provenance.yaml   # SLSA v1.0 attestation (keyless attestor)
    │   └── enforce-security-baseline.yaml # non-root, read-only FS, resource limits
    ├── network-policies/            # Zero-trust default-deny
    └── helm/java-healthcare-app     # Application Helm chart
```

---

## Generating an Audit Report

```bash
make audit-report
# Collects SLSA provenance, Cosign signatures, AI validation logs, scan results
# Packages and stores them in the S3 WORM bucket for HIPAA/FDA auditors
```

---

## Teardown

```bash
make destroy
# Removes the WORM bucket resources from state first (they carry prevent_destroy,
# which would otherwise abort the whole destroy), then destroys everything else.
# The WORM bucket and its evidence stay in AWS.
```

> **Warning:** The S3 WORM bucket cannot be deleted until the retention period expires
> (COMPLIANCE mode, 6 years). This is intentional for HIPAA compliance.

---

## Author

Emmanuel Ajebit
