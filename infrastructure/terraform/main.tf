terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source       = "./modules/vpc"
  project_name = var.project_name
  environment  = var.environment
}

module "eks" {
  source       = "./modules/eks"
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
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

# S3 WORM Audit Bucket
resource "aws_s3_bucket" "worm_audit" {
  bucket = "${var.project_name}-worm-audit-${var.environment}"
  tags   = { Project = var.project_name, Environment = var.environment }
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
      sse_algorithm = "aws:kms"
    }
  }
}

# DynamoDB Audit Table
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
  server_side_encryption  { enabled = true }

  tags = { Project = var.project_name, Environment = var.environment }
}
