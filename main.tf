terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

# Data source to get available AZs dynamically
data "aws_availability_zones" "available" {
  state = "available"
}

# Local values for dynamic configuration
locals {
  # Get available AZs in the region
  available_azs = data.aws_availability_zones.available.names
  az_count      = length(local.available_azs)

  # Calculate subnet count (use variable or default to AZ count)
  actual_subnet_count = var.subnet_count != null ? var.subnet_count : local.az_count

  # Calculate subnet bits for CIDR
  subnet_bits = ceil(log(local.actual_subnet_count * 2, 2))

  # Common tags
  common_tags = {
    Environment = "dev"
    ManagedBy   = "Terraform"
    Project     = "CSYE6225"
  }

  # Name prefix
  name_prefix = var.vpc_name
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = var.vpc_name
  })
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-igw"
  })
}

# Public Subnets with Ultra-Dynamic Distribution
resource "aws_subnet" "public" {
  count                   = local.actual_subnet_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, local.subnet_bits, count.index)
  availability_zone       = local.available_azs[count.index % local.az_count]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-public-subnet-${count.index + 1}"
    Type    = "subnet"
    SubType = "public"
    AZ      = local.available_azs[count.index % local.az_count]
    Purpose = "public-workloads"
  })
}

# Private Subnets with Ultra-Dynamic Distribution
resource "aws_subnet" "private" {
  count             = local.actual_subnet_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, local.subnet_bits, count.index + local.actual_subnet_count)
  availability_zone = local.available_azs[count.index % local.az_count]

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-private-subnet-${count.index + 1}"
    Type    = "subnet"
    SubType = "private"
    AZ      = local.available_azs[count.index % local.az_count]
    Purpose = "database-workloads"
  })
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-public-rt"
  })
}

# Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-private-rt"
  })
}

# Public Route
resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Public Route Table Associations
resource "aws_route_table_association" "public" {
  count          = local.actual_subnet_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Table Associations
resource "aws_route_table_association" "private" {
  count          = local.actual_subnet_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Application Security Group
resource "aws_security_group" "application" {
  name        = "${var.vpc_name}-application-sg"
  description = "Security group for web application"
  vpc_id      = aws_vpc.main.id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS access
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Application port
  ingress {
    description = "Application"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-application-sg"
  })
}

#######################################
# NEW RESOURCES FOR ASSIGNMENT 06
#######################################

# Random UUID for S3 Bucket Name (Globally Unique)
resource "random_uuid" "s3_bucket" {}

# Database Security Group
resource "aws_security_group" "database" {
  name        = "${var.vpc_name}-database-sg"
  description = "Security group for RDS database"
  vpc_id      = aws_vpc.main.id

  # Allow PostgreSQL traffic from application security group ONLY
  ingress {
    description     = "PostgreSQL from application"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }

  # Allow all outbound traffic
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-database-sg"
  })
}

# RDS Subnet Group
resource "aws_db_subnet_group" "main" {
  name        = "${var.vpc_name}-db-subnet-group"
  description = "Database subnet group for RDS"
  subnet_ids  = aws_subnet.private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-db-subnet-group"
  })
}

# RDS Parameter Group
resource "aws_db_parameter_group" "main" {
  name        = "${var.vpc_name}-db-parameter-group"
  family      = var.db_parameter_family
  description = "Custom parameter group for ${var.db_engine}"

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-db-parameter-group"
  })
}

# RDS Instance
resource "aws_db_instance" "main" {
  identifier     = "csye6225"
  engine         = var.db_engine
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp2"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = var.db_port

  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]

  publicly_accessible = false
  multi_az            = false

  skip_final_snapshot = true

  tags = merge(local.common_tags, {
    Name = "csye6225-rds-instance"
  })
}

# S3 Bucket for Image Storage (Using UUID)
resource "aws_s3_bucket" "images" {
  bucket        = random_uuid.s3_bucket.result
  force_destroy = true

  tags = merge(local.common_tags, {
    Name    = "${var.vpc_name}-images-${random_uuid.s3_bucket.result}"
    Type    = "s3-bucket"
    Purpose = "image-storage"
  })
}

# S3 Bucket Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 Bucket Public Access Block (Keep it Private)
resource "aws_s3_bucket_public_access_block" "images" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Bucket Lifecycle Policy
resource "aws_s3_bucket_lifecycle_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}

# IAM Role for EC2 Instance
resource "aws_iam_role" "ec2_role" {
  name = "${var.vpc_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-ec2-role"
  })
}

# IAM Policy for S3 Access
resource "aws_iam_role_policy" "s3_policy" {
  name = "${var.vpc_name}-s3-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.images.arn,
          "${aws_s3_bucket.images.arn}/*"
        ]
      }
    ]
  })
}

#######################################
# NEW FOR ASSIGNMENT 07: CloudWatch IAM Policy
#######################################

# Attach CloudWatch Agent Policy to EC2 Role
resource "aws_iam_role_policy_attachment" "cloudwatch_agent_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

#######################################
# END OF NEW ASSIGNMENT 07 CODE
#######################################

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.vpc_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-ec2-profile"
  })
}

# EC2 Instance with User Data
resource "aws_instance" "webapp" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.application.id]
  key_name               = var.ec2_key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size           = 25
    volume_type           = "gp2"
    delete_on_termination = true
  }

  disable_api_termination = false

  user_data = <<-EOF
              #!/bin/bash
              
              # Update environment file with RDS connection details
              cat > /opt/webapp/.env << 'ENVFILE'
              NODE_ENV=production
              PORT=${var.app_port}
              DB_HOST=${aws_db_instance.main.address}
              DB_PORT=${var.db_port}
              DB_USER=${var.db_username}
              DB_PASSWORD=${var.db_password}
              DB_NAME=${var.db_name}
              S3_BUCKET_NAME=${random_uuid.s3_bucket.result}
              AWS_REGION=${var.region}
              ENVFILE
              
              # Set proper ownership
              chown csye6225:csye6225 /opt/webapp/.env
              chmod 600 /opt/webapp/.env
              
              # Restart application service
              systemctl restart webapp.service
              EOF

  user_data_replace_on_change = true

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-webapp-instance"
  })

  depends_on = [aws_db_instance.main]
}