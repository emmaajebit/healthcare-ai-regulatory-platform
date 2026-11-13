# tvars.tf — Canonical variable declarations for the healthcare-ai platform.
# All runtime values supplied via environment-specific .tfvars files or
# pulled from Secrets Manager at deploy time. No sensitive defaults here.

# ─── Core ────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID — used to build ARNs and OIDC trust conditions"
  type        = string
}

variable "project_name" {
  description = "Prefix applied to every resource name and tag"
  type        = string
  default     = "healthcare-ai"
}

variable "environment" {
  description = "Deployment environment: dev | staging | prod"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

# ─── Keyless Auth / OIDC ─────────────────────────────────────────────────────

variable "github_org" {
  description = "GitHub organisation that owns the repository (no trailing slash)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name without the org prefix"
  type        = string
  default     = "healthcare-ai-regulatory-platform"
}

variable "github_oidc_thumbprints" {
  description = "SHA-1 thumbprints for token.actions.githubusercontent.com TLS cert chain"
  type        = list(string)
  default = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

variable "terraform_deployer_role_name" {
  description = "Name of the IAM role assumed by GitHub Actions to run Terraform apply"
  type        = string
  default     = "healthcare-ai-terraform-deployer"
}

variable "terraform_assume_role_arn" {
  description = "Optional IAM role ARN for the AWS provider to assume (empty = use caller identity)"
  type        = string
  default     = ""
}

# ─── State Backend ────────────────────────────────────────────────────────────

variable "tf_state_bucket" {
  description = "S3 bucket storing Terraform state (must exist before first apply)"
  type        = string
  default     = "healthcare-ai-terraform-state"
}

variable "tf_state_key" {
  description = "S3 object key for this module's state file"
  type        = string
  default     = "global/terraform.tfstate"
}

variable "tf_state_kms_alias" {
  description = "KMS alias used to encrypt the Terraform state bucket"
  type        = string
  default     = "alias/healthcare-ai-terraform-state"
}

# ─── Networking ───────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the platform VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to span (2 or 3)"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

# ─── EKS ─────────────────────────────────────────────────────────────────────

variable "eks_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.35" # 1.30 is past end of EKS extended support
}

variable "eks_endpoint_public_access" {
  description = "Expose the EKS API publicly (restricted by eks_public_access_cidrs). false = private-only; then run Ansible/CI from inside the VPC."
  type        = bool
  default     = true
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS endpoint. Set to your IP (x.x.x.x/32). GitHub-hosted runners need 0.0.0.0/0 — prefer self-hosted runners in the VPC instead."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.eks_public_access_cidrs) > 0
    error_message = "eks_public_access_cidrs must contain at least one CIDR."
  }
}

variable "eks_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_desired_size" {
  description = "Desired number of EKS worker nodes (>= 3 so Kyverno's 3 admission replicas can spread)"
  type        = number
  default     = 3
}

variable "eks_min_size" {
  description = "Minimum number of EKS worker nodes"
  type        = number
  default     = 3
}

variable "eks_max_size" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 5
}

# ─── ECR ─────────────────────────────────────────────────────────────────────

variable "ecr_lifecycle_keep_count" {
  description = "Number of tagged prod images to retain before expiring older ones"
  type        = number
  default     = 10
}

# ─── WORM / Compliance ────────────────────────────────────────────────────────

variable "worm_retention_days" {
  description = "Days to retain WORM audit objects in S3 (HIPAA minimum 6 years = 2190)"
  type        = number
  default     = 2190
}

# ─── Secrets Manager ──────────────────────────────────────────────────────────

variable "secrets_recovery_window_days" {
  description = "Days a secret is retained after deletion before permanent removal (0 = immediate)"
  type        = number
  default     = 7
}

variable "argocd_secret_path" {
  description = "Secrets Manager path for ArgoCD admin credentials"
  type        = string
  default     = "/healthcare-ai/argocd/admin"
}

variable "app_secrets_path" {
  description = "Secrets Manager path for application-layer secrets (JWT key, API keys)"
  type        = string
  default     = "/healthcare-ai/app/secrets"
}

variable "grafana_secret_path" {
  description = "Secrets Manager path for Grafana admin credentials (separate from ArgoCD)"
  type        = string
  default     = "/healthcare-ai/grafana/admin"
}

variable "helm_repo_secret_path" {
  description = "Secrets Manager path for private Helm repository token"
  type        = string
  default     = "/healthcare-ai/helm/repo-token"
}

# ─── Tagging ─────────────────────────────────────────────────────────────────

variable "additional_tags" {
  description = "Extra tags merged onto every resource — useful for cost-center, owner, etc."
  type        = map(string)
  default     = {}
}
