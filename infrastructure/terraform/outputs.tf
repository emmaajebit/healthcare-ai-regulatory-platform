output "eks_cluster_name" {
  description = "EKS cluster name (used in kubeconfig and Ansible inventory)"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  description = "ECR repository URL for docker push"
  value       = module.ecr.repository_url
}

output "opensearch_endpoint" {
  description = "OpenSearch Serverless endpoint for RAG Lambda"
  value       = module.opensearch_serverless.endpoint
}

output "worm_bucket_name" {
  description = "S3 WORM audit bucket name"
  value       = aws_s3_bucket.worm_audit.bucket
}

output "audit_dynamodb_table" {
  description = "DynamoDB audit log table name"
  value       = aws_dynamodb_table.audit_log.name
}
