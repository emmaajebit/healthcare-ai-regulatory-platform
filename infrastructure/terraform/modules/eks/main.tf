resource "aws_eks_cluster" "main" {
  # checkov:skip=CKV_AWS_39: PoC — GitHub-hosted Actions runners need API access (no VPC-attached runner)
  # checkov:skip=CKV_AWS_38: PoC — same reason; scope via VPC-attached runner for production
  name     = "${var.project_name}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  # EKS 1.30 is past end of extended support; 1.35 is on standard support
  # until March 2027 (docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).
  version = "1.35"

  vpc_config {
    subnet_ids = var.subnet_ids

    # PoC demo tradeoff: GitHub-hosted Actions runners must reach the API
    # server for kubectl/argocd (no VPC-attached runner in this PoC), so the
    # endpoint is public. For production, use endpoint_private_access only
    # plus a self-hosted runner inside the VPC.
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # CKV_AWS_37: full control-plane audit logging.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # CKV_AWS_58: Kubernetes secrets encrypted at rest with the platform CMK.
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = var.secrets_kms_key_arn
    }
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 5
  }

  instance_types = ["t3.medium"]
}

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-eks-nodes-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }

variable "project_name" {}
variable "vpc_id" {}
variable "subnet_ids" { type = list(string) }
variable "secrets_kms_key_arn" { type = string }
