# terraform/variables.tf
# Defines input variables for the root Terraform configuration.

variable "project_name" {
  description = "Name of the project for consistent naming."
  type        = string
  default     = "k8s-pipeline"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)."
  type        = string
}

variable "aws_region" {
  description = "AWS region where resources will be deployed."
  type        = string
  default     = "ap-south-1"
}

variable "tags" {
  description = "A map of tags to apply to all resources."
  type        = map(string)
  default = {
    "ManagedBy" = "Terraform"
    "CreatedBy" = "DevOpsTeam"
  }
}

# --- VPC Module Variables ---
variable "vpc_cidr_block" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets."
  type        = list(string)
}

# --- EKS Module Variables ---
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

variable "eks_endpoint_public_access" {
  description = "Controls whether the EKS cluster API server endpoint is publicly accessible."
  type        = bool
  default     = true # For demo simplicity, typically false for production unless restricted by CIDRs
}

variable "eks_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks that can access the EKS cluster API server endpoint when public access is enabled."
  type        = list(string)
  default     = ["0.0.0.0/0"] # WARNING: For demo ONLY. Restrict this in production!
}