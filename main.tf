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

  ssh_public_key   = var.ssh_public_key
  allowed_ssh_cidr = var.allowed_ssh_cidr

  anthropic_api_key = var.anthropic_api_key
  openai_api_key    = var.openai_api_key
  groq_api_key      = var.groq_api_key
  gemini_api_key    = var.gemini_api_key
  openclaw_version  = var.openclaw_version

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

  ssh_public_key   = var.ssh_public_key
  allowed_ssh_cidr = var.allowed_ssh_cidr

  anthropic_api_key = var.anthropic_api_key
  openai_api_key    = var.openai_api_key
  groq_api_key      = var.groq_api_key
  gemini_api_key    = var.gemini_api_key
  openclaw_version  = var.openclaw_version

  tailscale_enabled  = var.tailscale_enabled
  tailscale_auth_key = var.tailscale_auth_key
}
