variable "project_name"      { type = string }
variable "aws_region"        { type = string }
variable "aws_instance_type" { type = string }
variable "aws_ami_id"        { type = string }
variable "aws_disk_size_gb"  { type = number }

variable "aws_existing_volume_id" {
  type    = string
  default = ""
}

variable "ssh_public_key"    { type = string }
variable "allowed_ssh_cidr"  { type = string }
variable "tailscale_enabled" { type = bool }

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}

variable "anthropic_api_key" {
  type      = string
  sensitive = true
}

variable "openai_api_key" {
  type      = string
  sensitive = true
}

variable "groq_api_key" {
  type      = string
  sensitive = true
}

variable "gemini_api_key" {
  type      = string
  sensitive = true
}

variable "openclaw_version" { type = string }
