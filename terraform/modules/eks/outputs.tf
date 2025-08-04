# terraform/modules/eks/outputs.tf
# Outputs for the EKS module.

output "cluster_id" {
  description = "The name/ID of the EKS cluster."
  value       = aws_eks_cluster.this.id
}

output "cluster_endpoint" {
  description = "The endpoint for the EKS cluster API."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "The security group ID of the EKS cluster."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_name" {
  description = "The name of the EKS node group."
  value       = aws_eks_node_group.this.node_group_name
}