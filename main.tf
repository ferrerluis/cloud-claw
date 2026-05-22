# ─────────────────────────────────────────────────────────────────────────────
# Providers
# ─────────────────────────────────────────────────────────────────────────────

provider "aws" {
  region     = var.aws_region
  access_key = var.cloud_provider == "aws" ? (var.aws_access_key != "" ? var.aws_access_key : null) : "mock_access_key"
  secret_key = var.cloud_provider == "aws" ? (var.aws_secret_key != "" ? var.aws_secret_key : null) : "mock_secret_key"

  # These skip flags prevent hard validation failures when AWS credentials are
  # not supplied (i.e. when another cloud_provider is selected).
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

provider "digitalocean" {
  token = var.do_token != "" ? var.do_token : null
}

provider "hcloud" {
  token = var.hcloud_token != "" ? var.hcloud_token : null
}

resource "random_password" "gateway_token" {
  length  = 48
  special = false
}

resource "random_password" "hermes_api_server_key" {
  length  = 64
  special = false
}

resource "random_password" "n8n_encryption_key" {
  length  = 48
  special = false
}

resource "random_password" "postgres_password" {
  length  = 48
  special = false
}

resource "random_password" "ui_auth_password" {
  length  = 32
  special = false
}

locals {
  resolved_gateway_token         = trimspace(var.gateway_token) != "" ? var.gateway_token : random_password.gateway_token.result
  resolved_hermes_api_server_key = trimspace(var.hermes_api_server_key) != "" ? var.hermes_api_server_key : random_password.hermes_api_server_key.result
  resolved_n8n_encryption_key    = trimspace(var.n8n_encryption_key) != "" ? var.n8n_encryption_key : random_password.n8n_encryption_key.result
  resolved_postgres_password     = trimspace(var.postgres_password) != "" ? var.postgres_password : random_password.postgres_password.result
  resolved_ui_auth_password      = trimspace(var.ui_auth_password) != "" ? var.ui_auth_password : random_password.ui_auth_password.result
  openclaw_enabled               = contains(var.enabled_services, "openclaw")
  hermes_enabled                 = contains(var.enabled_services, "hermes")
  n8n_enabled                    = contains(var.enabled_services, "n8n")
  local_postgres_enabled         = local.n8n_enabled && var.n8n_database_mode == "local_postgres"
  public_base_domain             = trimspace(var.base_domain)
  resolved_openclaw_domain       = trimspace(var.openclaw_domain) != "" ? trimspace(var.openclaw_domain) : (local.public_base_domain != "" ? "openclaw.${local.public_base_domain}" : "")
  resolved_hermes_domain         = trimspace(var.hermes_domain) != "" ? trimspace(var.hermes_domain) : (local.public_base_domain != "" ? "hermes.${local.public_base_domain}" : "")
  resolved_n8n_domain            = trimspace(var.n8n_domain) != "" ? trimspace(var.n8n_domain) : (local.public_base_domain != "" ? "n8n.${local.public_base_domain}" : "")
  resolved_n8n_postgres_host     = var.n8n_database_mode == "local_postgres" ? "postgres" : trimspace(var.external_postgres_host)
  resolved_n8n_postgres_port     = var.n8n_database_mode == "local_postgres" ? 5432 : var.external_postgres_port
  resolved_n8n_postgres_database = var.n8n_database_mode == "local_postgres" ? var.postgres_database : var.external_postgres_database
  resolved_n8n_postgres_user     = var.n8n_database_mode == "local_postgres" ? var.postgres_user : var.external_postgres_user
  resolved_n8n_postgres_password = var.n8n_database_mode == "local_postgres" ? local.resolved_postgres_password : var.external_postgres_password
  resolved_n8n_postgres_ssl      = var.n8n_database_mode == "local_postgres" ? false : var.external_postgres_ssl_enabled
}

resource "terraform_data" "input_validation" {
  input = "agent-stack-input-validation"

  lifecycle {
    precondition {
      condition = (
        !var.public_domain_enabled ||
        trimspace(var.base_domain) != "" ||
        trimspace(var.openclaw_domain) != "" ||
        trimspace(var.hermes_domain) != "" ||
        trimspace(var.n8n_domain) != ""
      )
      error_message = "public_domain_enabled requires base_domain or at least one explicit service domain."
    }

    precondition {
      condition     = !var.public_domain_enabled || var.ui_auth_mode == "basic"
      error_message = "public_domain_enabled supports ui_auth_mode = \"basic\" only in v1."
    }

    precondition {
      condition = (
        var.n8n_database_mode != "external_postgres" ||
        (
          trimspace(var.external_postgres_host) != "" &&
          trimspace(var.external_postgres_database) != "" &&
          trimspace(var.external_postgres_user) != "" &&
          trimspace(var.external_postgres_password) != ""
        )
      )
      error_message = "n8n_database_mode = \"external_postgres\" requires external_postgres_host, external_postgres_database, external_postgres_user, and external_postgres_password."
    }
  }
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
  anthropic_auth_key                   = var.anthropic_auth_key
  openai_api_key                       = var.openai_api_key
  openai_codex_auth_json_base64        = var.openai_codex_auth_json_base64
  groq_api_key                         = var.groq_api_key
  gemini_api_key                       = var.gemini_api_key
  telegram_bot_token                   = var.telegram_bot_token
  telegram_allow_from                  = var.telegram_allow_from
  openclaw_config_mode                 = var.openclaw_config_mode
  agent_channel                        = var.agent_channel
  model_providers_enabled              = var.model_providers_enabled
  default_model                        = var.default_model
  fallback_models                      = var.fallback_models
  openclaw_version                     = var.openclaw_version
  openclaw_node_options                = var.openclaw_node_options
  openclaw_swap_size_mb                = var.openclaw_swap_size_mb
  openclaw_health_start_period_seconds = var.openclaw_health_start_period_seconds
  openclaw_health_retries              = var.openclaw_health_retries
  seed_starter_workspace_files         = var.seed_starter_workspace_files
  starter_soul_profile                 = var.starter_soul_profile
  gateway_token                        = local.resolved_gateway_token
  enabled_services                     = var.enabled_services
  hermes_image                         = var.hermes_image
  hermes_dashboard_enabled             = var.hermes_dashboard_enabled
  hermes_api_server_enabled            = var.hermes_api_server_enabled
  hermes_api_server_key                = local.resolved_hermes_api_server_key
  n8n_image                            = var.n8n_image
  n8n_database_mode                    = var.n8n_database_mode
  n8n_encryption_key                   = local.resolved_n8n_encryption_key
  n8n_public_webhooks_enabled          = var.n8n_public_webhooks_enabled
  n8n_generic_timezone                 = var.n8n_generic_timezone
  postgres_image                       = var.postgres_image
  postgres_database                    = var.postgres_database
  postgres_user                        = var.postgres_user
  postgres_password                    = local.resolved_postgres_password
  n8n_postgres_host                    = local.resolved_n8n_postgres_host
  n8n_postgres_port                    = local.resolved_n8n_postgres_port
  n8n_postgres_database                = local.resolved_n8n_postgres_database
  n8n_postgres_user                    = local.resolved_n8n_postgres_user
  n8n_postgres_password                = local.resolved_n8n_postgres_password
  n8n_postgres_ssl_enabled             = local.resolved_n8n_postgres_ssl
  public_domain_enabled                = var.public_domain_enabled
  openclaw_domain                      = local.resolved_openclaw_domain
  hermes_domain                        = local.resolved_hermes_domain
  n8n_domain                           = local.resolved_n8n_domain
  acme_email                           = var.acme_email
  ui_auth_mode                         = var.ui_auth_mode
  ui_auth_username                     = var.ui_auth_username
  ui_auth_password                     = local.resolved_ui_auth_password

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
  anthropic_auth_key                   = var.anthropic_auth_key
  openai_api_key                       = var.openai_api_key
  openai_codex_auth_json_base64        = var.openai_codex_auth_json_base64
  groq_api_key                         = var.groq_api_key
  gemini_api_key                       = var.gemini_api_key
  telegram_bot_token                   = var.telegram_bot_token
  telegram_allow_from                  = var.telegram_allow_from
  openclaw_config_mode                 = var.openclaw_config_mode
  agent_channel                        = var.agent_channel
  model_providers_enabled              = var.model_providers_enabled
  default_model                        = var.default_model
  fallback_models                      = var.fallback_models
  openclaw_version                     = var.openclaw_version
  openclaw_node_options                = var.openclaw_node_options
  openclaw_swap_size_mb                = var.openclaw_swap_size_mb
  openclaw_health_start_period_seconds = var.openclaw_health_start_period_seconds
  openclaw_health_retries              = var.openclaw_health_retries
  seed_starter_workspace_files         = var.seed_starter_workspace_files
  starter_soul_profile                 = var.starter_soul_profile
  gateway_token                        = local.resolved_gateway_token
  enabled_services                     = var.enabled_services
  hermes_image                         = var.hermes_image
  hermes_dashboard_enabled             = var.hermes_dashboard_enabled
  hermes_api_server_enabled            = var.hermes_api_server_enabled
  hermes_api_server_key                = local.resolved_hermes_api_server_key
  n8n_image                            = var.n8n_image
  n8n_database_mode                    = var.n8n_database_mode
  n8n_encryption_key                   = local.resolved_n8n_encryption_key
  n8n_public_webhooks_enabled          = var.n8n_public_webhooks_enabled
  n8n_generic_timezone                 = var.n8n_generic_timezone
  postgres_image                       = var.postgres_image
  postgres_database                    = var.postgres_database
  postgres_user                        = var.postgres_user
  postgres_password                    = local.resolved_postgres_password
  n8n_postgres_host                    = local.resolved_n8n_postgres_host
  n8n_postgres_port                    = local.resolved_n8n_postgres_port
  n8n_postgres_database                = local.resolved_n8n_postgres_database
  n8n_postgres_user                    = local.resolved_n8n_postgres_user
  n8n_postgres_password                = local.resolved_n8n_postgres_password
  n8n_postgres_ssl_enabled             = local.resolved_n8n_postgres_ssl
  public_domain_enabled                = var.public_domain_enabled
  openclaw_domain                      = local.resolved_openclaw_domain
  hermes_domain                        = local.resolved_hermes_domain
  n8n_domain                           = local.resolved_n8n_domain
  acme_email                           = var.acme_email
  ui_auth_mode                         = var.ui_auth_mode
  ui_auth_username                     = var.ui_auth_username
  ui_auth_password                     = local.resolved_ui_auth_password

  tailscale_enabled  = var.tailscale_enabled
  tailscale_auth_key = var.tailscale_auth_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Hetzner deployment (activated when cloud_provider = "hetzner")
# ─────────────────────────────────────────────────────────────────────────────

module "hetzner" {
  count  = var.cloud_provider == "hetzner" ? 1 : 0
  source = "./modules/hetzner"

  project_name                         = var.project_name
  admin_username                       = var.admin_username
  hcloud_location                      = var.hcloud_location
  hcloud_server_type                   = var.hcloud_server_type
  hcloud_image                         = var.hcloud_image
  hcloud_disk_size_gb                  = var.hcloud_disk_size_gb
  hcloud_existing_volume_id            = var.hcloud_existing_volume_id
  ssh_public_key                       = local.resolved_ssh_public_key
  allowed_ssh_cidr                     = var.allowed_ssh_cidr
  anthropic_api_key                    = var.anthropic_api_key
  anthropic_auth_key                   = var.anthropic_auth_key
  openai_api_key                       = var.openai_api_key
  openai_codex_auth_json_base64        = var.openai_codex_auth_json_base64
  groq_api_key                         = var.groq_api_key
  gemini_api_key                       = var.gemini_api_key
  telegram_bot_token                   = var.telegram_bot_token
  telegram_allow_from                  = var.telegram_allow_from
  openclaw_config_mode                 = var.openclaw_config_mode
  agent_channel                        = var.agent_channel
  model_providers_enabled              = var.model_providers_enabled
  default_model                        = var.default_model
  fallback_models                      = var.fallback_models
  openclaw_version                     = var.openclaw_version
  openclaw_node_options                = var.openclaw_node_options
  openclaw_swap_size_mb                = var.openclaw_swap_size_mb
  openclaw_health_start_period_seconds = var.openclaw_health_start_period_seconds
  openclaw_health_retries              = var.openclaw_health_retries
  seed_starter_workspace_files         = var.seed_starter_workspace_files
  starter_soul_profile                 = var.starter_soul_profile
  gateway_token                        = local.resolved_gateway_token
  enabled_services                     = var.enabled_services
  hermes_image                         = var.hermes_image
  hermes_dashboard_enabled             = var.hermes_dashboard_enabled
  hermes_api_server_enabled            = var.hermes_api_server_enabled
  hermes_api_server_key                = local.resolved_hermes_api_server_key
  n8n_image                            = var.n8n_image
  n8n_database_mode                    = var.n8n_database_mode
  n8n_encryption_key                   = local.resolved_n8n_encryption_key
  n8n_public_webhooks_enabled          = var.n8n_public_webhooks_enabled
  n8n_generic_timezone                 = var.n8n_generic_timezone
  postgres_image                       = var.postgres_image
  postgres_database                    = var.postgres_database
  postgres_user                        = var.postgres_user
  postgres_password                    = local.resolved_postgres_password
  n8n_postgres_host                    = local.resolved_n8n_postgres_host
  n8n_postgres_port                    = local.resolved_n8n_postgres_port
  n8n_postgres_database                = local.resolved_n8n_postgres_database
  n8n_postgres_user                    = local.resolved_n8n_postgres_user
  n8n_postgres_password                = local.resolved_n8n_postgres_password
  n8n_postgres_ssl_enabled             = local.resolved_n8n_postgres_ssl
  public_domain_enabled                = var.public_domain_enabled
  openclaw_domain                      = local.resolved_openclaw_domain
  hermes_domain                        = local.resolved_hermes_domain
  n8n_domain                           = local.resolved_n8n_domain
  acme_email                           = var.acme_email
  ui_auth_mode                         = var.ui_auth_mode
  ui_auth_username                     = var.ui_auth_username
  ui_auth_password                     = local.resolved_ui_auth_password
  tailscale_enabled                    = var.tailscale_enabled
  tailscale_auth_key                   = var.tailscale_auth_key
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
