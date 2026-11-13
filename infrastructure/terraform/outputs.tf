# outputs.tf — All outputs are structured for direct consumption by
# the terraform-to-ansible.sh bridge script. Sensitive ARNs are marked
# sensitive = true so they are redacted from plan logs.

# ─── EKS ─────────────────────────────────────────────────────────────────────

output "eks_cluster_name" {
  description = "EKS cluster name (used in kubeconfig and Ansible inventory)"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

# ─── ECR ─────────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "ECR repository URL for docker push / Ansible fact"
  value       = module.ecr.repository_url
}

# ─── OpenSearch ───────────────────────────────────────────────────────────────

output "opensearch_endpoint" {
  description = "OpenSearch Serverless endpoint for RAG Lambda"
  value       = module.opensearch_serverless.endpoint
}

# ─── Storage ──────────────────────────────────────────────────────────────────

output "worm_bucket_name" {
  description = "S3 WORM audit bucket name"
  value       = aws_s3_bucket.worm_audit.bucket
}

output "audit_dynamodb_table" {
  description = "DynamoDB audit log table name"
  value       = aws_dynamodb_table.audit_log.name
}

# ─── OIDC / Auth ─────────────────────────────────────────────────────────────

output "terraform_deployer_role_arn" {
  description = "IAM role ARN for GitHub Actions terraform apply (paste into workflow role-to-assume)"
  value       = aws_iam_role.terraform_deployer.arn
}

output "terraform_planner_role_arn" {
  description = "IAM role ARN for GitHub Actions terraform plan on pull requests"
  value       = aws_iam_role.terraform_planner.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

# ─── Secrets Manager ──────────────────────────────────────────────────────────

output "secrets_kms_key_arn" {
  description = "KMS key ARN used to encrypt all Secrets Manager secrets"
  value       = aws_kms_key.secrets.arn
  sensitive   = true
}

output "argocd_secret_arn" {
  description = "Secrets Manager ARN for ArgoCD admin credentials (Ansible fetches at deploy time)"
  value       = aws_secretsmanager_secret.argocd.arn
  sensitive   = true
}

output "app_secret_arn" {
  description = "Secrets Manager ARN for application secrets (JWT key, API keys)"
  value       = aws_secretsmanager_secret.app.arn
  sensitive   = true
}

output "grafana_secret_arn" {
  description = "Secrets Manager ARN for Grafana admin credentials (Ansible fetches at deploy time)"
  value       = aws_secretsmanager_secret.grafana.arn
  sensitive   = true
}

output "helm_repo_secret_arn" {
  description = "Secrets Manager ARN for private Helm repository token"
  value       = aws_secretsmanager_secret.helm_repo.arn
  sensitive   = true
}

output "secrets_reader_policy_arn" {
  description = "IAM policy ARN to attach to IRSA roles that need to read app secrets"
  value       = aws_iam_policy.secrets_reader.arn
}

# ─── Region / Account ─────────────────────────────────────────────────────────

output "aws_region" {
  description = "AWS region all resources are deployed into"
  value       = var.aws_region
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
  sensitive   = true
}
