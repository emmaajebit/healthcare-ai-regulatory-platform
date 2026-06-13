variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "healthcare-ai"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "worm_retention_days" {
  description = "Number of days to retain WORM audit objects in S3 (HIPAA minimum: 6 years = 2190 days)"
  type        = number
  default     = 2190
}
