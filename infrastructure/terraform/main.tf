terraform {
  required_version = "~> 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    },
    var.additional_tags
  )
}

provider "aws" {
  region = var.aws_region

  # When running in GitHub Actions, credentials arrive via OIDC token exchange
  # (no long-lived keys). assume_role is optional — set terraform_assume_role_arn
  # to further scope down the effective permissions.
  dynamic "assume_role" {
    for_each = var.terraform_assume_role_arn != "" ? [var.terraform_assume_role_arn] : []
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = local.common_tags
  }
}

# ─── Modules ──────────────────────────────────────────────────────────────────

module "vpc" {
  source          = "./modules/vpc"
  project_name    = var.project_name
  environment     = var.environment
  log_kms_key_arn = aws_kms_key.secrets.arn
}

module "eks" {
  source              = "./modules/eks"
  project_name        = var.project_name
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnet_ids
  secrets_kms_key_arn = aws_kms_key.secrets.arn

  eks_version            = var.eks_version
  endpoint_public_access = var.eks_endpoint_public_access
  public_access_cidrs    = var.eks_public_access_cidrs
  instance_types         = var.eks_instance_types
  desired_size           = var.eks_desired_size
  min_size               = var.eks_min_size
  max_size               = var.eks_max_size
  admin_role_arns        = [aws_iam_role.terraform_deployer.arn]
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
}

module "opensearch_serverless" {
  source       = "./modules/opensearch_serverless"
  project_name = var.project_name
  environment  = var.environment
}

# ─── S3 WORM Audit Bucket ─────────────────────────────────────────────────────

resource "aws_s3_bucket" "worm_audit" {
  bucket = "${var.project_name}-worm-audit-${var.environment}"

  # Object Lock requires versioning enabled from creation (CKV_AWS_21).
  object_lock_enabled = true

  # Audit evidence must never be destroyed by Terraform. NOTE: this makes a
  # plain `terraform destroy` abort entirely — use `make destroy`, which
  # removes the WORM resources from state first (the bucket is retained).
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "worm" {
  bucket = aws_s3_bucket.worm_audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

# CKV2_AWS_6: block all public access on the audit bucket.
resource "aws_s3_bucket_public_access_block" "worm" {
  bucket                  = aws_s3_bucket.worm_audit.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# CKV2_AWS_61: lifecycle — noncurrent versions expire only after the full
# WORM retention period (Object Lock COMPLIANCE prevents earlier deletion).
resource "aws_s3_bucket_lifecycle_configuration" "worm" {
  bucket = aws_s3_bucket.worm_audit.id
  rule {
    id     = "expire-noncurrent-after-retention"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = var.worm_retention_days
    }
  }

  # Audit objects are rarely read after the first month; Intelligent-Tiering
  # cuts storage cost without retrieval fees or minimum-duration penalties.
  rule {
    id     = "intelligent-tiering"
    status = "Enabled"
    filter {}
    transition {
      days          = 0
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

resource "aws_s3_bucket_object_lock_configuration" "worm" {
  bucket = aws_s3_bucket.worm_audit.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.worm_retention_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "worm" {
  bucket = aws_s3_bucket.worm_audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.secrets.arn
    }
    bucket_key_enabled = true
  }
}

# ─── DynamoDB Audit Log ───────────────────────────────────────────────────────
# NOTE: this DynamoDB table is for HIPAA audit logging, not for Terraform state
# locking. State locking now uses S3 native locking (use_lockfile in backend.tf).

resource "aws_dynamodb_table" "audit_log" {
  name         = "${var.project_name}-bedrock-audit-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "audit_id"
  range_key    = "timestamp"

  attribute {
    name = "audit_id"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }

  point_in_time_recovery { enabled = true }

  # CKV_AWS_119: encrypt the audit table with the platform CMK.
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.secrets.arn
  }
}
