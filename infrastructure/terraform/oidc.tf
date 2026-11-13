# oidc.tf — Keyless authentication via GitHub Actions OIDC.
# GitHub exchanges a short-lived OIDC token for temporary STS credentials.
# No long-lived AWS keys are stored in GitHub Secrets or anywhere else.
#
# GitHub Actions workflow usage:
#   - uses: aws-actions/configure-aws-credentials@v4
#     with:
#       role-to-assume: <terraform_deployer_role_arn output>
#       aws-region: us-east-1

data "aws_caller_identity" "current" {}

# ── OIDC Identity Provider ────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints

  tags = merge(local.common_tags, { Name = "${var.project_name}-github-oidc" })
}

# ── Deployer Role (terraform apply — main branch only) ────────────────────────

resource "aws_iam_role" "terraform_deployer" {
  name        = var.terraform_deployer_role_name
  description = "Assumed by GitHub Actions via OIDC for terraform apply on main"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDCDeploy"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            # Restrict to main branch only for apply
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, { Name = var.terraform_deployer_role_name })
}

# ── Planner Role (terraform plan — any branch / pull request) ─────────────────

resource "aws_iam_role" "terraform_planner" {
  name        = "${var.project_name}-terraform-planner"
  description = "Assumed by GitHub Actions via OIDC for terraform plan on pull requests"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDCPlan"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Allow any branch / pull_request trigger
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-terraform-planner" })
}

# ── Deployer Policy ───────────────────────────────────────────────────────────

resource "aws_iam_role_policy" "terraform_deployer" {
  name = "terraform-deployer-inline"
  role = aws_iam_role.terraform_deployer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3StateLock"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
        ]
        Resource = [
          "arn:aws:s3:::${var.tf_state_bucket}",
          "arn:aws:s3:::${var.tf_state_bucket}/*",
        ]
      },
      {
        Sid    = "KMSState"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = [
          "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*",
        ]
        Condition = {
          StringLike = { "kms:RequestAlias" = var.tf_state_kms_alias }
        }
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:/healthcare-ai/*",
        ]
      },
      {
        Sid      = "EKSFull"
        Effect   = "Allow"
        Action   = ["eks:*"]
        Resource = "*"
      },
      {
        Sid      = "IAMPassRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = ["eks.amazonaws.com", "ec2.amazonaws.com"]
          }
        }
      },
    ]
  })
}

# Planner gets AWS ReadOnlyAccess
resource "aws_iam_role_policy_attachment" "terraform_planner_readonly" {
  role       = aws_iam_role.terraform_planner.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# use_lockfile: even a read-only planner must be able to create and delete the
# state lock object (<key>.tflock) for terraform plan to run safely.
resource "aws_iam_role_policy" "terraform_planner_lockfile" {
  name = "state-lockfile-access"
  role = aws_iam_role.terraform_planner.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateLockfile"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.tf_state_bucket}/global/terraform.tfstate.tflock"
      },
      {
        Sid       = "StateKeyRead"
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource  = ["*"]
        Condition = { StringLike = { "kms:RequestAlias" = var.tf_state_kms_alias } }
      }
    ]
  })
}

# PoC shortcut: the deployer applies the ENTIRE platform (VPC, EKS, ECR, IAM
# roles + OIDC provider, OpenSearch Serverless, DynamoDB, Secrets Manager,
# CloudWatch, KMS, S3) — a scoped policy for that surface is large. Attach
# AdministratorAccess for the PoC and scope down before production use.
resource "aws_iam_role_policy_attachment" "terraform_deployer_admin" {
  # checkov:skip=CKV_AWS_274: PoC shortcut — the deployer applies the whole platform; scope down before production
  role       = aws_iam_role.terraform_deployer.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
