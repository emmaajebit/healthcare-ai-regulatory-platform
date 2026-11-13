resource "aws_opensearchserverless_collection" "rag" {
  name = "${var.project_name}-rag-${var.environment}"
  type = "VECTORSEARCH"
}

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${var.project_name}-encryption"
  type = "encryption"
  policy = jsonencode({
    Rules       = [{ Resource = ["collection/${var.project_name}-rag-${var.environment}"], ResourceType = "collection" }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${var.project_name}-network"
  type = "network"
  policy = jsonencode([{
    Rules           = [{ Resource = ["collection/${var.project_name}-rag-${var.environment}"], ResourceType = "collection" }]
    AllowFromPublic = false
  }])
}

output "endpoint" { value = aws_opensearchserverless_collection.rag.collection_endpoint }

variable "project_name" {}
variable "environment" {}
