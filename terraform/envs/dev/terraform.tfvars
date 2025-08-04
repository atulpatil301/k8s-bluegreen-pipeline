# terraform/envs/dev/terraform.tfvars
# Variables specific to the 'dev' environment.

environment = "dev"
aws_region  = "ap-south-1" # Or your preferred region for development (must match AWS CLI profile region)

vpc_cidr_block      = "10.0.0.0/16"
public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

cluster_version = "1.32" # EKS Kubernetes version
instance_type   = "t3.small" # Essential for AWS Free Tier
desired_size    = 2          # Start with 1 to stay within Free Tier limits
max_size        = 2          # Allows for a little scaling, still mindful of costs
min_size        = 2

eks_endpoint_public_access       = true
# WARNING: "0.0.0.0/0" means public access from anywhere.
# FOR SECURITY: Replace "0.0.0.0/0" with your public IP address's CIDR (e.g., "103.X.Y.Z/32")
# You can find your public IP by searching "what is my ip" on Google.
eks_endpoint_public_access_cidrs = ["0.0.0.0/0"]