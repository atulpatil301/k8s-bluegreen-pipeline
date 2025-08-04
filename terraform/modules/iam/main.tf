# terraform/modules/iam/main.tf
# Defines IAM roles and policy attachments for the EKS Cluster and Worker Nodes.
# -------------------------------------------------------------
# IAM Role for EKS Cluster Control Plane
# This role allows the EKS control plane to create AWS resources like Load Balancers,
# attach ENIs, etc.
# -------------------------------------------------------------
resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.project_name}-${var.environment}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

# -------------------------------------------------------------
# IAM Role for EKS Managed Node Group
# This role allows EC2 instances to join the EKS cluster, communicate with the control plane,
# pull images from ECR, and interact with the EBS CSI driver.
# -------------------------------------------------------------
resource "aws_iam_role" "eks_node_group_role" {
  name = "${var.project_name}-${var.environment}-eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = var.tags
}

# Attach standard EKS worker node policies
resource "aws_iam_role_policy_attachment" "eks_node_group_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "eks_node_group_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "eks_node_group_ecr_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group_role.name
}

# --- CRITICAL ADDITION: Attach AmazonEBSCSIDriverPolicy to the EKS Worker Node Role ---
# This policy provides permissions for EC2 instances to interact with EBS volumes,
# which is needed by the EBS CSI driver (especially if IRSA fallback occurs).
resource "aws_iam_role_policy_attachment" "eks_node_group_ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.eks_node_group_role.name
}
