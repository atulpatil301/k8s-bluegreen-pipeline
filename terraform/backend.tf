# terraform/backend.tf
# Configures the local backend for Terraform state.
# WARNING: This is NOT recommended for team collaboration or production environments.
# The state file (terraform.tfstate) will be stored locally in the terraform/ directory.

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  # No 'backend "local"' block is needed. Terraform defaults to local if no backend is specified.
  # If you wanted to explicitly set a custom path for the local state, you would do:
  # backend "local" {
  #   path = "terraform.tfstate" # This is the default path anyway
  # }
}

# AWS Provider configuration
provider "aws" {
  region = var.aws_region
}