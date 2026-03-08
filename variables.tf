# ─────────────────────────────────────────────────────────
# Provider selection
# ─────────────────────────────────────────────────────────

variable "cloud_provider" {
  description = "Which cloud provider to deploy on. Valid values: \"aws\" or \"digitalocean\"."
  type        = string
  default     = "aws"

  validation {
    condition     = contains(["aws", "digitalocean"], var.cloud_provider)
    error_message = "cloud_provider must be \"aws\" or \"digitalocean\"."
  }
}

variable "project_name" {
  description = "Short name used to tag/name all created resources (e.g. \"openclaw\" or \"mybot\")."
  type        = string
  default     = "openclaw"
}

variable "admin_username" {
  description = "OS username to use for SSH/admin access across providers."
  type        = string
  default     = "admin"

  validation {
    condition = (
      can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username)) &&
      var.admin_username != "root"
    )
    error_message = "admin_username must be a valid Linux username and cannot be \"root\"."
  }
}

# ─────────────────────────────────────────────────────────
# AWS
# ─────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "aws_access_key" {
  description = "AWS access key ID. Leave blank to rely on environment variables or instance profiles."
  type        = string
  default     = ""
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS secret access key. Leave blank to rely on environment variables or instance profiles."
  type        = string
  default     = ""
  sensitive   = true
}

variable "aws_instance_type" {
  description = "EC2 instance type. Default t3.small (1 vCPU / 2 GB). Use t3.medium for 4 GB, t3.large for 8 GB."
  type        = string
  default     = "t3.small"
}

variable "aws_ami_id" {
  description = "AMI ID to use. Leave blank to auto-select the latest Ubuntu 22.04 LTS in the chosen region."
  type        = string
  default     = ""
}

variable "aws_disk_size_gb" {
  description = "Size in GB for the EBS data volume (separate from the 20 GB OS root disk)."
  type        = number
  default     = 50
}

variable "aws_existing_volume_id" {
  description = "EBS volume ID (e.g. \"vol-0abc123\") to attach instead of creating a new one. Leave blank to create a fresh volume."
  type        = string
  default     = ""
}

# ─────────────────────────────────────────────────────────
# DigitalOcean
# ─────────────────────────────────────────────────────────

variable "do_token" {
  description = "DigitalOcean API token."
  type        = string
  default     = ""
  sensitive   = true
}

variable "do_region" {
  description = "DigitalOcean region slug (e.g. \"nyc3\", \"sfo3\", \"fra1\")."
  type        = string
  default     = "nyc3"
}

variable "do_droplet_size" {
  description = "Droplet size slug. Default s-2vcpu-2gb (Basic 2 GB / 2 vCPU, 60 GB root disk). Use s-2vcpu-4gb for 4 GB RAM."
  type        = string
  default     = "s-2vcpu-2gb"
}

variable "do_disk_size_gb" {
  description = "Size in GB for the extra DigitalOcean Block Storage volume. The Droplet root disk is already 60 GB; this volume is for portable persistent data."
  type        = number
  default     = 20
}

variable "do_existing_volume_id" {
  description = "Existing DigitalOcean volume ID to attach instead of creating a new one. Must also set do_existing_volume_name."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.do_existing_volume_id) == "" ||
      trimspace(var.do_existing_volume_name) != ""
    )
    error_message = "When do_existing_volume_id is set, do_existing_volume_name must also be set."
  }
}

variable "do_existing_volume_name" {
  description = "Name of the existing DigitalOcean volume (required when do_existing_volume_id is set, used to derive the device path)."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.do_existing_volume_name) == "" ||
      trimspace(var.do_existing_volume_id) != ""
    )
    error_message = "do_existing_volume_name can only be set when do_existing_volume_id is also set."
  }
}

# ─────────────────────────────────────────────────────────
# SSH / network
# ─────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key content (e.g. contents of ~/.ssh/id_ed25519.pub)."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR that is allowed to reach port 22. Restrict to your own IP for best security (e.g. \"203.0.113.5/32\")."
  type        = string
  default     = "0.0.0.0/0"
}

# ─────────────────────────────────────────────────────────
# OpenClaw / LLM API keys
# ─────────────────────────────────────────────────────────

variable "anthropic_api_key" {
  description = "Anthropic API key for Claude models."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openai_api_key" {
  description = "OpenAI API key for GPT models."
  type        = string
  default     = ""
  sensitive   = true
}

variable "groq_api_key" {
  description = "Groq API key for fast open-weight inference."
  type        = string
  default     = ""
  sensitive   = true
}

variable "gemini_api_key" {
  description = "Google Gemini API key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openclaw_version" {
  description = "OpenClaw Docker image tag (e.g. \"latest\" or a pinned version)."
  type        = string
  default     = "latest"
}

# ─────────────────────────────────────────────────────────
# Tailscale
# ─────────────────────────────────────────────────────────

variable "tailscale_enabled" {
  description = "Install Tailscale for private access to the OpenClaw dashboard. Strongly recommended — disabling this leaves the dashboard accessible only via SSH tunnel."
  type        = bool
  default     = true
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key (generate one-time or reusable keys at https://login.tailscale.com/admin/settings/keys)."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition = (
      var.tailscale_enabled == false ||
      trimspace(var.tailscale_auth_key) != ""
    )
    error_message = "tailscale_auth_key must be set when tailscale_enabled is true."
  }
}
