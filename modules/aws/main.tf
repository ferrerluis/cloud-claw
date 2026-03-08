terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Data sources
# ─────────────────────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  count       = var.aws_ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Locals
# ─────────────────────────────────────────────────────────────────────────────

locals {
  az     = data.aws_availability_zones.available.names[0]
  ami_id = var.aws_ami_id != "" ? var.aws_ami_id : one(data.aws_ami.ubuntu[*].id)

  # If an existing volume ID is provided, use it; otherwise reference the new one.
  # Use one(resource[*].id) instead of resource[0].id so Terraform doesn't error
  # when count = 0 (Terraform evaluates both ternary branches regardless of condition).
  ebs_volume_id = var.aws_existing_volume_id != "" ? var.aws_existing_volume_id : one(aws_ebs_volume.this[*].id)

  cloud_init = templatefile("${path.module}/../common/templates/cloud_init.yaml.tpl", {
    provider_type        = "aws"
    project_name         = var.project_name
    admin_username       = var.admin_username
    admin_ssh_public_key = var.ssh_public_key
    ebs_volume_id        = local.ebs_volume_id
    do_volume_name       = ""
    anthropic_api_key    = var.anthropic_api_key
    openai_api_key       = var.openai_api_key
    groq_api_key         = var.groq_api_key
    gemini_api_key       = var.gemini_api_key
    tailscale_enabled    = var.tailscale_enabled
    tailscale_auth_key   = var.tailscale_auth_key
    openclaw_version     = var.openclaw_version
    gateway_token        = var.gateway_token
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Networking
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-subnet" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.project_name}-rt" }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

# ─────────────────────────────────────────────────────────────────────────────
# Security group — SSH only (+ Tailscale UDP if enabled)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "this" {
  name        = "${var.project_name}-sg"
  description = "OpenClaw: SSH access only. Tailscale handles private dashboard access."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  dynamic "ingress" {
    for_each = var.tailscale_enabled ? [1] : []
    content {
      description = "Tailscale VPN (UDP 41641)"
      from_port   = 41641
      to_port     = 41641
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH key pair
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_key_pair" "this" {
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key
}

# ─────────────────────────────────────────────────────────────────────────────
# EBS data volume (separate from root disk, survives instance replacement)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ebs_volume" "this" {
  count             = var.aws_existing_volume_id == "" ? 1 : 0
  availability_zone = local.az
  size              = var.aws_disk_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name    = "${var.project_name}-data"
    Project = var.project_name
  }

  lifecycle {
    # Prevent accidental data loss on terraform destroy
    prevent_destroy = false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# EC2 instance
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_instance" "this" {
  ami                    = local.ami_id
  instance_type          = var.aws_instance_type
  subnet_id              = aws_subnet.this.id
  vpc_security_group_ids = [aws_security_group.this.id]
  key_name               = aws_key_pair.this.key_name
  availability_zone      = local.az

  # user_data includes rendered cloud-init which embeds the EBS volume ID
  user_data                   = local.cloud_init
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  tags = {
    Name    = "${var.project_name}"
    Project = var.project_name
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Attach data volume to instance
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_volume_attachment" "this" {
  # /dev/xvdf is the requested name; on Nitro instances the OS will see it as
  # /dev/nvme1n1 (or similar). The bootstrap script finds the device by NVMe
  # serial number (EBS volume ID without dashes) — see cloud_init.yaml.tpl.
  device_name = "/dev/xvdf"
  volume_id   = local.ebs_volume_id
  instance_id = aws_instance.this.id

  # Don't forcibly detach — safer for running workloads
  force_detach = false

  # If re-using an existing volume, skip the detach on destroy to protect data
  skip_destroy = var.aws_existing_volume_id != ""
}
