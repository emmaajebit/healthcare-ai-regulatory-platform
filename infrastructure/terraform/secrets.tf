# secrets.tf — AWS Secrets Manager resources.
# Terraform creates the secret *container* but never writes the real value into
# state. Placeholders are seeded on first apply; lifecycle ignore_changes prevents
# Terraform from overwriting values that operators set out-of-band.

# ── KMS Key for Secrets Encryption ───────────────────────────────────────────

resource "aws_kms_key" "secrets" {
  description             = "${var.project_name} Secrets Manager CMK"
  deletion_window_in_days = 14
  enable_key_rotation     = true
  tags                    = merge(local.common_tags, { Name = "${var.project_name}-secrets-kms" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ── ArgoCD Admin Credentials ──────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "argocd" {
  name                    = var.argocd_secret_path
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = var.secrets_recovery_window_days
  description             = "ArgoCD admin credentials — ${var.project_name}/${var.environment}"
  tags                    = merge(local.common_tags, { SecretType = "argocd" })
}

resource "aws_secretsmanager_secret_version" "argocd" {
  secret_id = aws_secretsmanager_secret.argocd.id
  secret_string = jsonencode({
    username = "admin"
    password = "REPLACE_VIA_AWS_CONSOLE_OR_CLI"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── Application Secrets ───────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "app" {
  name                    = var.app_secrets_path
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = var.secrets_recovery_window_days
  description             = "Application secrets: JWT signing key, Bedrock API key, external APIs"
  tags                    = merge(local.common_tags, { SecretType = "application" })
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    jwt_signing_key = "REPLACE_VIA_AWS_CONSOLE_OR_CLI"
    bedrock_api_key = "REPLACE_VIA_AWS_CONSOLE_OR_CLI"
    openai_api_key  = "REPLACE_VIA_AWS_CONSOLE_OR_CLI"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── Helm Repository Token ─────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "helm_repo" {
  name                    = var.helm_repo_secret_path
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = var.secrets_recovery_window_days
  description             = "Private Helm repository authentication token"
  tags                    = merge(local.common_tags, { SecretType = "helm" })
}

resource "aws_secretsmanager_secret_version" "helm_repo" {
  secret_id = aws_secretsmanager_secret.helm_repo.id
  secret_string = jsonencode({
    username = "REPLACE_VIA_AWS_CONSOLE_OR_CLI"
    token    = "REPLACE_VIA_AWS_CONSOLE_OR_CLI"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── IAM Policy: Allow EKS pods to read secrets via IRSA ──────────────────────

resource "aws_iam_policy" "secrets_reader" {
  name        = "${var.project_name}-secrets-reader"
  description = "Allows reading healthcare-ai secrets from Secrets Manager (attach to IRSA roles)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = [
          aws_secretsmanager_secret.app.arn,
          aws_secretsmanager_secret.argocd.arn,
        ]
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [aws_kms_key.secrets.arn]
      },
    ]
  })

  tags = local.common_tags
}
