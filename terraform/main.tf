# terraform/main.tf
# Calls the different infrastructure modules.

# Data source for available AZs (used by VPC module)
data "aws_availability_zones" "available" {
  state = "available"
}

# -------------------------------------------------------------
# Module: IAM Roles
# -------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags
}

# -------------------------------------------------------------
# Module: VPC
# -------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  project_name          = var.project_name
  environment           = var.environment
  vpc_cidr_block        = var.vpc_cidr_block
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  availability_zones    = data.aws_availability_zones.available.names
  tags                  = var.tags
}

# -------------------------------------------------------------
# Module: EKS Cluster
# -------------------------------------------------------------
module "eks" {
  source = "./modules/eks"

  project_name                     = var.project_name
  environment                      = var.environment
  cluster_version                  = var.cluster_version
  instance_type                    = var.instance_type
  desired_size                     = var.desired_size
  max_size                         = var.max_size
  min_size                         = var.min_size
  vpc_id                           = module.vpc.vpc_id
  public_subnet_ids                = module.vpc.public_subnet_ids
  private_subnet_ids               = module.vpc.private_subnet_ids
  eks_cluster_role_arn             = module.iam.eks_cluster_role_arn
  eks_node_group_role_arn          = module.iam.eks_node_group_role_arn
  eks_endpoint_public_access       = var.eks_endpoint_public_access
  eks_endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs
  tags                             = var.tags

  # Ensure IAM roles and their policies are fully provisioned before creating EKS cluster
  # This dependency is crucial because the EKS cluster needs its role to exist and be ready.
  depends_on = [
    module.iam.eks_cluster_role_arn,         # Ensure the cluster role exists
    module.iam.eks_node_group_role_arn       # Ensure the node group role exists
    # The policy attachments happen within the IAM module, and by ensuring the role ARNs are ready,
    # Terraform's graph should correctly handle implicit dependencies on policy attachments.
  ]
}

# -------------------------------------------------------------
# Resource: ECR Repository for Application
# -------------------------------------------------------------
resource "aws_ecr_repository" "nodejs_app_repo" {
  name                 = "${var.project_name}/${var.environment}/nodejs-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-nodejs-app-ecr"
    "Environment" = var.environment
  })
}

resource "aws_ecr_lifecycle_policy" "nodejs_app_policy" {
  repository = aws_ecr_repository.nodejs_app_repo.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Expire images older than 14 days",
        selection = {
          tagStatus   = "untagged",
          countType   = "sinceImagePushed",
          countUnit   = "days",
          countNumber = 7
        },
        action = {
          type = "expire"
        }
      }
    ]
  })
}