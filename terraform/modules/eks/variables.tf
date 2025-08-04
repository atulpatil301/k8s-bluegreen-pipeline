# terraform/modules/eks/variables.tf
# Variables for the EKS module.

variable "project_name" {
  description = "Name of the project."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for EKS worker nodes."
  type        = string
}

variable "desired_size" {
  description = "Desired number of worker nodes in the EKS cluster."
  type        = number
}

variable "max_size" {
  description = "Maximum number of worker nodes in the EKS cluster."
  type        = number
}

variable "min_size" {
  description = "Minimum number of worker nodes in the EKS cluster."
  type        = number
}

variable "vpc_id" {
  description = "The ID of the VPC where the EKS cluster will be deployed."
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for control plane EFS/ALB (if needed)."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EKS worker nodes."
  type        = list(string)
}

variable "eks_cluster_role_arn" {
  description = "ARN of the IAM role for the EKS cluster."
  type        = string
}

variable "eks_node_group_role_arn" {
  description = "ARN of the IAM role for EKS worker nodes."
  type        = string
}

variable "eks_endpoint_public_access" {
  description = "Controls whether the EKS cluster API server endpoint is publicly accessible."
  type        = bool
}

variable "eks_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks that can access the EKS cluster API server endpoint when public access is enabled."
  type        = list(string)
}

variable "tags" {
  description = "A map of tags to apply to all resources."
  type        = map(string)
}