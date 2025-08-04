# terraform/modules/eks/main.tf
# Defines the AWS EKS Cluster and Node Groups.

resource "aws_eks_cluster" "this" {
  name     = "${var.project_name}-${var.environment}-eks"
  role_arn = var.eks_cluster_role_arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids             = var.private_subnet_ids # EKS ENIs in private subnets
    endpoint_private_access = true # EKS control plane private endpoint
    endpoint_public_access  = var.eks_endpoint_public_access
    public_access_cidrs     = var.eks_endpoint_public_access_cidrs
  }

  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-eks"
    "Environment" = var.environment
  })

  # Ensure the cluster is created before trying to create node groups
  # Implicit dependency on role_arn from the IAM module is usually sufficient.
  # Explicit depends_on is handled at the root module level if needed for ordering.
}

# EKS Managed Node Group
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-${var.environment}-worker-nodes"
  node_role_arn   = var.eks_node_group_role_arn
  subnet_ids      = var.private_subnet_ids # Worker nodes in private subnets
  instance_types  = [var.instance_type]

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  disk_size = 20 # 20GB should be fine for Free Tier for /dev/xvda

  # Label nodes for better scheduling
  labels = {
    "environment" = var.environment
    "project"     = var.project_name
  }

  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-worker-node"
    "Environment" = var.environment
  })

  # Dependencies on IAM policies are managed by the IAM module and root main.tf
}