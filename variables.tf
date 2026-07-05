# ─────────────────────────────────────────────────────────
# Provider selection
# ─────────────────────────────────────────────────────────

variable "cloud_provider" {
  description = "Which cloud provider to deploy on. Valid values: \"aws\", \"digitalocean\", or \"hetzner\"."
  type        = string
  default     = "aws"

  validation {
    condition     = contains(["aws", "digitalocean", "hetzner"], var.cloud_provider)
    error_message = "cloud_provider must be \"aws\", \"digitalocean\", or \"hetzner\"."
  }
}

variable "project_name" {
  description = "Short name used to tag/name all created resources."
  type        = string
  default     = "agent-stack"
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
}

# ─────────────────────────────────────────────────────────
# Hetzner Cloud
# ─────────────────────────────────────────────────────────

variable "hcloud_token" {
  description = "Hetzner Cloud API token."
  type        = string
  default     = ""
  sensitive   = true
}

variable "hcloud_location" {
  description = "Hetzner Cloud location slug (for example \"ash\", \"hil\", \"fsn1\", \"nbg1\", or \"hel1\")."
  type        = string
  default     = "ash"
}

variable "hcloud_server_type" {
  description = "Hetzner Cloud server type. Default cpx21 is sized for the full AgentStack profile."
  type        = string
  default     = "cpx21"
}

variable "hcloud_image" {
  description = "Hetzner Cloud image slug."
  type        = string
  default     = "ubuntu-22.04"
}

variable "hcloud_disk_size_gb" {
  description = "Size in GB for the extra Hetzner Cloud volume."
  type        = number
  default     = 50
}

variable "hcloud_existing_volume_id" {
  description = "Existing Hetzner Cloud volume ID to attach instead of creating a new one."
  type        = string
  default     = ""
}

# ─────────────────────────────────────────────────────────
# SSH / network
# ─────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key content. If empty, Terraform auto-resolves/creates a repo-local keypair and uses its .pub content."
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR that is allowed to reach port 22. Restrict to your own IP for best security (e.g. \"203.0.113.5/32\")."
  type        = string
  default     = "0.0.0.0/0"
}

variable "generate_repo_ssh_config" {
  description = "If true, terraform apply writes ./.ssh/config with the current instance IP and SSH defaults."
  type        = bool
  default     = true
}

variable "repo_ssh_host_alias" {
  description = "Host alias written into ./.ssh/config."
  type        = string
  default     = "agent-stack"
}

variable "repo_ssh_identity_file" {
  description = "IdentityFile value written into ./.ssh/config."
  type        = string
  default     = "./.ssh/id_ed25519_agent_stack"
}

variable "repo_ssh_private_key_path" {
  description = "Repo-relative private key path used for auto key resolution/generation when ssh_public_key is empty."
  type        = string
  default     = ".ssh/id_ed25519_agent_stack"
}

# ─────────────────────────────────────────────────────────
# OpenClaw / LLM API keys
# ─────────────────────────────────────────────────────────

variable "anthropic_api_key" {
  description = "Anthropic API key for Claude models. This is the preferred Anthropic credential for AgentStack."
  type        = string
  default     = ""
  sensitive   = true
}

variable "anthropic_auth_key" {
  description = "Legacy Anthropic setup-token for Claude Code style auth flows. Optional and not recommended for normal AgentStack setup; prefer anthropic_api_key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openai_api_key" {
  description = "OpenAI API key for openai/* models when openai_auth_mode = \"api_key\"."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openai_auth_mode" {
  description = "Auth/runtime mode for openai/* models. api_key uses OPENAI_API_KEY; codex routes OpenAI model refs through imported Codex ChatGPT subscription auth."
  type        = string
  default     = "api_key"

  validation {
    condition     = contains(["api_key", "codex"], var.openai_auth_mode)
    error_message = "openai_auth_mode must be one of: api_key, codex."
  }
}

variable "openai_codex_auth_json_base64" {
  description = "Base64-encoded contents of ~/.codex/auth.json for subscription-backed OpenAI models when openai_auth_mode = \"codex\". Leave blank unless you want to import an existing Codex CLI login."
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

variable "telegram_bot_token" {
  description = "Telegram BotFather token used to preconfigure channels.telegram.botToken."
  type        = string
  default     = ""
  sensitive   = true
}

variable "telegram_allow_from" {
  description = "Optional list of pre-approved Telegram user IDs for DM access (channels.telegram.allowFrom)."
  type        = list(string)
  default     = []
}

variable "openclaw_config_mode" {
  description = "Controls bootstrap edits to openclaw.json. auto=preserve existing config / manage fresh installs, manage=always apply starter bootstrap edits, preserve=skip optional edits."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "manage", "preserve"], var.openclaw_config_mode)
    error_message = "openclaw_config_mode must be one of: auto, manage, preserve."
  }
}

variable "agent_channel" {
  description = "Primary channel plugin to bootstrap. Valid values: \"telegram\" or \"whatsapp\"."
  type        = string
  default     = "telegram"

  validation {
    condition     = contains(["telegram", "whatsapp"], var.agent_channel)
    error_message = "agent_channel must be \"telegram\" or \"whatsapp\"."
  }
}

variable "model_providers_enabled" {
  description = "Required list of model providers to configure at bootstrap. Allowed values: anthropic, openai, google, groq."
  type        = list(string)

  validation {
    condition = (
      length(var.model_providers_enabled) > 0 &&
      alltrue([
        for provider in var.model_providers_enabled : contains(["anthropic", "openai", "google", "groq"], provider)
      ])
    )
    error_message = "model_providers_enabled must include at least one provider and only: anthropic, openai, google, groq."
  }
}

variable "default_model" {
  description = "Required default model reference to set during bootstrap (for example \"anthropic/claude-haiku-4-5\")."
  type        = string

  validation {
    condition     = trimspace(var.default_model) != ""
    error_message = "default_model is required and cannot be empty."
  }
}

variable "fallback_models" {
  description = "Required ordered list of fallback model references to configure at bootstrap (can be an empty list)."
  type        = list(string)
}

variable "openclaw_version" {
  description = "OpenClaw Docker image tag (e.g. \"latest\" or a pinned version)."
  type        = string
  default     = "latest"
}

variable "openclaw_node_options" {
  description = "Optional NODE_OPTIONS passed to the OpenClaw container (e.g. \"--max-old-space-size=1536\")."
  type        = string
  default     = ""
}

variable "openclaw_swap_size_mb" {
  description = "Optional swap size in MB created at bootstrap time (set > 0 for small RAM nodes, e.g. 2048)."
  type        = number
  default     = 0
}

variable "openclaw_health_start_period_seconds" {
  description = "Docker healthcheck start_period in seconds for OpenClaw container warm-up."
  type        = number
  default     = 120
}

variable "openclaw_health_retries" {
  description = "Docker healthcheck retries before marking OpenClaw unhealthy."
  type        = number
  default     = 8
}

variable "seed_starter_workspace_files" {
  description = "If true, bootstrap creates starter workspace files (SOUL.md, AGENTS.md, TOOLS.md, USER.md) when missing."
  type        = bool
  default     = true
}

variable "starter_soul_profile" {
  description = "Starter SOUL.md profile to seed. Valid values: \"balanced\", \"builder\", \"researcher\"."
  type        = string
  default     = "balanced"

  validation {
    condition     = contains(["balanced", "builder", "researcher"], var.starter_soul_profile)
    error_message = "starter_soul_profile must be one of: balanced, builder, researcher."
  }
}

variable "gateway_token" {
  description = "Gateway token used by the Control UI/WebSocket auth. Leave blank to auto-generate and persist in Terraform state."
  type        = string
  default     = ""
  sensitive   = true
}

# ─────────────────────────────────────────────────────────
# Agent / automation stack
# ─────────────────────────────────────────────────────────

variable "enabled_services" {
  description = "Services to run on the instance. Allowed values: openclaw, hermes, n8n, workspace."
  type        = list(string)
  default     = ["openclaw", "hermes", "n8n"]

  validation {
    condition = (
      length(var.enabled_services) > 0 &&
      alltrue([
        for service in var.enabled_services : contains(["openclaw", "hermes", "n8n", "workspace"], service)
      ])
    )
    error_message = "enabled_services must include at least one service and only: openclaw, hermes, n8n, workspace."
  }
}

variable "workspace_username" {
  description = "Username created inside the optional workspace container."
  type        = string
  default     = "user"

  validation {
    condition = (
      can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.workspace_username)) &&
      var.workspace_username != "root"
    )
    error_message = "workspace_username must be a valid Linux username and cannot be \"root\"."
  }
}

variable "workspace_password" {
  description = "Password for SSH access to the optional workspace container. Required when enabled_services includes workspace."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition = (
      !contains(var.enabled_services, "workspace") ||
      trimspace(var.workspace_password) != ""
    )
    error_message = "workspace_password must be set when enabled_services includes workspace."
  }
}

variable "workspace_ssh_host_port" {
  description = "Host port mapped to SSH inside the optional workspace container. Do not open this port in provider firewalls."
  type        = number
  default     = 2222

  validation {
    condition     = var.workspace_ssh_host_port >= 1024 && var.workspace_ssh_host_port <= 65535
    error_message = "workspace_ssh_host_port must be between 1024 and 65535."
  }
}

variable "workspace_ssh_public_keys" {
  description = "OpenSSH public keys authorized for the optional workspace user. Supply public key strings only, never private keys or local agent/socket paths."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for key in var.workspace_ssh_public_keys : can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)\\s+\\S+(\\s+.*)?$", trimspace(key)))
    ])
    error_message = "workspace_ssh_public_keys entries must be OpenSSH public key strings, not private keys, file paths, or agent socket paths."
  }
}

variable "hermes_image" {
  description = "Hermes Agent Docker image."
  type        = string
  default     = "nousresearch/hermes-agent:latest"
}

variable "hermes_dashboard_enabled" {
  description = "Run the Hermes dashboard side-process inside the Hermes gateway container."
  type        = bool
  default     = true
}

variable "hermes_api_server_enabled" {
  description = "Enable the Hermes OpenAI-compatible API server."
  type        = bool
  default     = true
}

variable "hermes_api_server_key" {
  description = "Hermes API server key. Leave blank to auto-generate and persist in Terraform state."
  type        = string
  default     = ""
  sensitive   = true
}

variable "n8n_image" {
  description = "n8n Docker image."
  type        = string
  default     = "docker.n8n.io/n8nio/n8n:stable"
}

variable "n8n_database_mode" {
  description = "Database mode for n8n. local_postgres runs Postgres on the persistent volume; external_postgres uses the supplied connection settings."
  type        = string
  default     = "local_postgres"

  validation {
    condition     = contains(["local_postgres", "external_postgres"], var.n8n_database_mode)
    error_message = "n8n_database_mode must be \"local_postgres\" or \"external_postgres\"."
  }
}

variable "n8n_encryption_key" {
  description = "n8n encryption key. Leave blank to auto-generate and persist in Terraform state."
  type        = string
  default     = ""
  sensitive   = true
}

variable "n8n_public_webhooks_enabled" {
  description = "When public domains are enabled, leave n8n webhook routes unauthenticated for external services."
  type        = bool
  default     = true
}

variable "n8n_generic_timezone" {
  description = "Timezone passed to n8n's GENERIC_TIMEZONE setting."
  type        = string
  default     = "America/New_York"
}

variable "postgres_image" {
  description = "Postgres Docker image used when n8n_database_mode = local_postgres."
  type        = string
  default     = "postgres:17-alpine"
}

variable "postgres_database" {
  description = "Local Postgres database name for n8n."
  type        = string
  default     = "n8n"
}

variable "postgres_user" {
  description = "Local Postgres username for n8n."
  type        = string
  default     = "n8n"
}

variable "postgres_password" {
  description = "Local Postgres password. Leave blank to auto-generate and persist in Terraform state."
  type        = string
  default     = ""
  sensitive   = true
}

variable "external_postgres_host" {
  description = "External Postgres host used when n8n_database_mode = external_postgres."
  type        = string
  default     = ""
}

variable "external_postgres_port" {
  description = "External Postgres port used when n8n_database_mode = external_postgres."
  type        = number
  default     = 5432
}

variable "external_postgres_database" {
  description = "External Postgres database used when n8n_database_mode = external_postgres."
  type        = string
  default     = "n8n"
}

variable "external_postgres_user" {
  description = "External Postgres user used when n8n_database_mode = external_postgres."
  type        = string
  default     = "n8n"
}

variable "external_postgres_password" {
  description = "External Postgres password used when n8n_database_mode = external_postgres."
  type        = string
  default     = ""
  sensitive   = true
}

variable "external_postgres_ssl_enabled" {
  description = "Enable SSL for n8n's external Postgres connection."
  type        = bool
  default     = true
}

variable "public_domain_enabled" {
  description = "Expose selected UIs through public HTTPS domains behind a reverse-proxy login."
  type        = bool
  default     = false
}

variable "base_domain" {
  description = "Base domain used to derive service hostnames when public_domain_enabled = true (openclaw.<base>, hermes.<base>, n8n.<base>)."
  type        = string
  default     = ""
}

variable "openclaw_domain" {
  description = "Explicit public domain for the OpenClaw UI. Overrides base_domain derivation."
  type        = string
  default     = ""
}

variable "hermes_domain" {
  description = "Explicit public domain for the Hermes dashboard/API. Overrides base_domain derivation."
  type        = string
  default     = ""
}

variable "n8n_domain" {
  description = "Explicit public domain for the n8n UI and webhooks. Overrides base_domain derivation."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Email address Caddy uses for ACME certificate registration. Optional, but recommended when public domains are enabled."
  type        = string
  default     = ""
}

variable "ui_auth_mode" {
  description = "Reverse-proxy UI auth mode. v1 supports basic auth only."
  type        = string
  default     = "basic"

  validation {
    condition     = contains(["basic"], var.ui_auth_mode)
    error_message = "ui_auth_mode must be \"basic\"."
  }
}

variable "ui_auth_username" {
  description = "Username for the public-domain reverse-proxy login."
  type        = string
  default     = "admin"
}

variable "ui_auth_password" {
  description = "Password for the public-domain reverse-proxy login. Leave blank to auto-generate and persist in Terraform state."
  type        = string
  default     = ""
  sensitive   = true
}

# ─────────────────────────────────────────────────────────
# Tailscale
# ─────────────────────────────────────────────────────────

variable "tailscale_enabled" {
  description = "Install Tailscale for private access to selected AgentStack UIs. Strongly recommended — disabling this leaves UIs accessible only via SSH tunnel unless public domains are enabled."
  type        = bool
  default     = true
}

variable "tailscale_mode" {
  description = "How to run Tailscale when enabled. sidecar preserves the existing Docker sidecar; host installs and manages tailscaled directly on the VM."
  type        = string
  default     = "sidecar"

  validation {
    condition     = contains(["sidecar", "host"], var.tailscale_mode)
    error_message = "tailscale_mode must be one of: sidecar, host."
  }
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
