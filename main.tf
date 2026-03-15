# ─────────────────────────────────────────────────────────────────────────────
# Providers
# ─────────────────────────────────────────────────────────────────────────────

provider "aws" {
  region     = var.aws_region
  access_key = var.cloud_provider == "aws" ? (var.aws_access_key != "" ? var.aws_access_key : null) : "mock_access_key"
  secret_key = var.cloud_provider == "aws" ? (var.aws_secret_key != "" ? var.aws_secret_key : null) : "mock_secret_key"

  # These skip flags prevent hard validation failures when AWS credentials are
  # not supplied (i.e. when cloud_provider = "digitalocean").
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

provider "digitalocean" {
  token = var.do_token != "" ? var.do_token : null
}

resource "random_password" "gateway_token" {
  length  = 48
  special = false
}

locals {
  resolved_gateway_token = trimspace(var.gateway_token) != "" ? var.gateway_token : random_password.gateway_token.result
}

data "external" "repo_ssh_public_key" {
  count = trimspace(var.ssh_public_key) == "" ? 1 : 0

  program = ["python3", "${path.root}/scripts/resolve_ssh_public_key.py"]
  query = {
    repo_root           = path.root
    private_key_relpath = var.repo_ssh_private_key_path
  }
}

locals {
  resolved_ssh_public_key = trimspace(var.ssh_public_key) != "" ? var.ssh_public_key : data.external.repo_ssh_public_key[0].result.ssh_public_key
  resolved_ssh_key_source = trimspace(var.ssh_public_key) != "" ? "tfvars_or_env" : data.external.repo_ssh_public_key[0].result.source
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS deployment (activated when cloud_provider = "aws")
# ─────────────────────────────────────────────────────────────────────────────

module "aws" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  source = "./modules/aws"

  project_name           = var.project_name
  admin_username         = var.admin_username
  aws_region             = var.aws_region
  aws_instance_type      = var.aws_instance_type
  aws_ami_id             = var.aws_ami_id
  aws_disk_size_gb       = var.aws_disk_size_gb
  aws_existing_volume_id = var.aws_existing_volume_id

  ssh_public_key   = local.resolved_ssh_public_key
  allowed_ssh_cidr = var.allowed_ssh_cidr

  anthropic_api_key                    = var.anthropic_api_key
  openai_api_key                       = var.openai_api_key
  groq_api_key                         = var.groq_api_key
  gemini_api_key                       = var.gemini_api_key
  telegram_bot_token                   = var.telegram_bot_token
  telegram_allow_from                  = var.telegram_allow_from
  openclaw_version                     = var.openclaw_version
  openclaw_node_options                = var.openclaw_node_options
  openclaw_swap_size_mb                = var.openclaw_swap_size_mb
  openclaw_health_start_period_seconds = var.openclaw_health_start_period_seconds
  openclaw_health_retries              = var.openclaw_health_retries
  gateway_token                        = local.resolved_gateway_token

  tailscale_enabled  = var.tailscale_enabled
  tailscale_auth_key = var.tailscale_auth_key
}

# ─────────────────────────────────────────────────────────────────────────────
# DigitalOcean deployment (activated when cloud_provider = "digitalocean")
# ─────────────────────────────────────────────────────────────────────────────

module "digitalocean" {
  count  = var.cloud_provider == "digitalocean" ? 1 : 0
  source = "./modules/digitalocean"

  project_name    = var.project_name
  admin_username  = var.admin_username
  do_region       = var.do_region
  do_droplet_size = var.do_droplet_size
  do_disk_size_gb = var.do_disk_size_gb

  do_existing_volume_id   = var.do_existing_volume_id
  do_existing_volume_name = var.do_existing_volume_name

  ssh_public_key   = local.resolved_ssh_public_key
  allowed_ssh_cidr = var.allowed_ssh_cidr

  anthropic_api_key                    = var.anthropic_api_key
  openai_api_key                       = var.openai_api_key
  groq_api_key                         = var.groq_api_key
  gemini_api_key                       = var.gemini_api_key
  telegram_bot_token                   = var.telegram_bot_token
  telegram_allow_from                  = var.telegram_allow_from
  openclaw_version                     = var.openclaw_version
  openclaw_node_options                = var.openclaw_node_options
  openclaw_swap_size_mb                = var.openclaw_swap_size_mb
  openclaw_health_start_period_seconds = var.openclaw_health_start_period_seconds
  openclaw_health_retries              = var.openclaw_health_retries
  gateway_token                        = local.resolved_gateway_token

  tailscale_enabled  = var.tailscale_enabled
  tailscale_auth_key = var.tailscale_auth_key
}

resource "local_file" "repo_ssh_config" {
  count = var.generate_repo_ssh_config ? 1 : 0

  filename        = "${path.root}/.ssh/config"
  file_permission = "0600"
  content         = <<-EOT
Host ${var.repo_ssh_host_alias}
  HostName ${local.instance_public_ip}
  User ${var.admin_username}
  IdentityFile ${var.repo_ssh_identity_file}
  IdentitiesOnly yes
  ConnectTimeout 10
  ServerAliveInterval 20
  ServerAliveCountMax 3
  TCPKeepAlive yes
  StrictHostKeyChecking accept-new
EOT
}
