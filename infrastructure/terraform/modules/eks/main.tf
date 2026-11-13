resource "aws_eks_cluster" "main" {
  # checkov:skip=CKV_AWS_39: PoC — GitHub-hosted Actions runners need API access (no VPC-attached runner)
  # checkov:skip=CKV_AWS_38: PoC — same reason; scope via VPC-attached runner for production
  name     = "${var.project_name}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  # EKS 1.30 is past end of extended support; 1.35 is on standard support
  # until March 2027 (docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).
  version = var.eks_version

  # EKS access entries instead of hand-patching the aws-auth ConfigMap
  # (a merge-patch of mapRoles overwrites the node-role mapping and breaks nodes).
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = var.subnet_ids

    # Reachability for Ansible / kubectl / CI (pick ONE in tfvars):
    #   a) PoC: public endpoint, restricted with eks_public_access_cidrs
    #      (GitHub-hosted runners use wide, changing IP ranges, so CI needs
    #      0.0.0.0/0 here — or option b).
    #   b) Production: eks_endpoint_public_access = false, and run Ansible
    #      from an SSM bastion in the VPC + self-hosted runners in the VPC
    #      (set the DEPLOY_RUNNER repo variable to their label).
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
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

  # Kyverno runs 3 admission-controller replicas; keep >= 3 nodes so they
  # can spread across nodes/AZs.
  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  instance_types = var.instance_types
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

# ── Cluster access for CI (replaces the aws-auth ConfigMap patch) ────────────
resource "aws_eks_access_entry" "admins" {
  for_each      = toset(var.admin_role_arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admins" {
  for_each      = toset(var.admin_role_arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}

output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }

variable "project_name" {}
variable "vpc_id" {}
variable "subnet_ids" { type = list(string) }
variable "secrets_kms_key_arn" { type = string }
variable "eks_version" { type = string }
variable "endpoint_public_access" { type = bool }
variable "public_access_cidrs" { type = list(string) }
variable "instance_types" { type = list(string) }
variable "desired_size" { type = number }
variable "min_size" { type = number }
variable "max_size" { type = number }
variable "admin_role_arns" {
  description = "IAM role ARNs granted cluster-admin via EKS access entries (e.g. the CI deployer role)"
  type        = list(string)
  default     = []
}
