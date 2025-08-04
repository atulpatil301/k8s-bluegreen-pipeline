# terraform/modules/iam/outputs.tf
# Outputs for IAM roles.

output "eks_cluster_role_arn" {
  description = "ARN of the IAM role for the EKS cluster."
  value       = aws_iam_role.eks_cluster_role.arn
}

output "eks_node_group_role_arn" {
  description = "ARN of the IAM role for EKS worker nodes."
  value       = aws_iam_role.eks_node_group_role.arn
}
