

# Look up existing VPC
data "aws_vpc" "imported_vpc" {
  id = var.vpc_id
}

# Find subnets with auto-assign public IP enabled
data "aws_subnets" "public_subnets" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Find latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Create Security Group for the Linux instance
resource "aws_security_group" "linux_sg" {
  name        = "LinuxInstanceSG"
  description = "Security group for Linux EC2 instance"
  vpc_id      = data.aws_vpc.imported_vpc.id

  # Allow SSH inbound
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Consider restricting to specific IPs in production
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "LinuxInstanceSG"
  }
}

# Create IAM role for SSM
resource "aws_iam_role" "ec2_ssm_role" {
  name = "Ec2SsmRole"

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
}

# Attach SSM policy to the IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an instance profile for the IAM role
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2-instance-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# Launch an EC2 instance with Amazon Linux
resource "aws_instance" "linux_instance" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small"
  subnet_id              = length(data.aws_subnets.public_subnets.ids) > 0 ? data.aws_subnets.public_subnets.ids[0] : null
  vpc_security_group_ids = [aws_security_group.linux_sg.id]
  key_name               = var.key_pair_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance_profile.name
  associate_public_ip_address = true

  tags = {
    Name = "LinuxInstance"
  }

  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.public_subnets.ids) > 0
      error_message = "No subnets with auto-assign public IP enabled were found in the VPC. Please enable auto-assign public IP on at least one subnet."
    }
  }
}
