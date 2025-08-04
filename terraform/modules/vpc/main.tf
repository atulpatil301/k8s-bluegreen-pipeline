# terraform/modules/vpc/main.tf
# Defines the AWS VPC and associated networking components.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-vpc"
    "Environment" = var.environment
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-igw"
    "Environment" = var.environment
  })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Place NAT Gateway in the first public subnet

  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-natgw"
    "Environment" = var.environment
  })

  # Depends on the public subnet and its route table being ready
  depends_on = [aws_internet_gateway.this, aws_subnet.public]
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-eip-nat"
    "Environment" = var.environment
  })
}

# Public Subnets
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  map_public_ip_on_launch = true # Instances in public subnets get public IPs

  tags = merge(var.tags, {
    "Name"                              = "${var.project_name}-${var.environment}-public-subnet-${var.availability_zones[count.index]}"
    "Environment"                       = var.environment
    "kubernetes.io/role/elb"            = "1" # Tag for Kubernetes Load Balancer Controller
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-eks" = "owned" # Required for EKS to auto-discover
  })
}

# Private Subnets
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  map_public_ip_on_launch = false # No public IPs in private subnets

  tags = merge(var.tags, {
    "Name"                              = "${var.project_name}-${var.environment}-private-subnet-${var.availability_zones[count.index]}"
    "Environment"                       = var.environment
    "kubernetes.io/role/internal-elb"   = "1" # Tag for Kubernetes internal Load Balancer
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-eks" = "owned" # Required for EKS to auto-discover
  })
}

# Route Tables for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-public-rt"
    "Environment" = var.environment
  })
}

resource "aws_route" "public_internet_gateway" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Route Tables for Private Subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    "Name"        = "${var.project_name}-${var.environment}-private-rt"
    "Environment" = var.environment
  })
}

resource "aws_route" "private_nat_gateway" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}