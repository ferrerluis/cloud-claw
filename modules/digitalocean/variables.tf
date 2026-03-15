variable "project_name" { type = string }
variable "admin_username" { type = string }
variable "do_region" { type = string }
variable "do_droplet_size" { type = string }
variable "do_disk_size_gb" { type = number }

variable "do_existing_volume_id" {
  type    = string
  default = ""
}

variable "do_existing_volume_name" {
  type    = string
  default = ""
}

variable "ssh_public_key" { type = string }
variable "allowed_ssh_cidr" { type = string }
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

variable "telegram_bot_token" {
  type      = string
  sensitive = true
}

variable "telegram_allow_from" {
  type = list(string)
}

variable "openclaw_version" { type = string }
variable "openclaw_node_options" { type = string }
variable "openclaw_swap_size_mb" { type = number }
variable "openclaw_health_start_period_seconds" { type = number }
variable "openclaw_health_retries" { type = number }

variable "gateway_token" {
  type      = string
  sensitive = true
}
