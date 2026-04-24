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
  default     = "cloud-claw"
}

variable "repo_ssh_identity_file" {
  description = "IdentityFile value written into ./.ssh/config."
  type        = string
  default     = "./.ssh/id_ed25519_cloud_claw"
}

variable "repo_ssh_private_key_path" {
  description = "Repo-relative private key path used for auto key resolution/generation when ssh_public_key is empty."
  type        = string
  default     = ".ssh/id_ed25519_cloud_claw"
}

# ─────────────────────────────────────────────────────────
# OpenClaw / LLM API keys
# ─────────────────────────────────────────────────────────

variable "anthropic_api_key" {
  description = "Anthropic API key for Claude models. This is the preferred Anthropic credential for cloud-claw."
  type        = string
  default     = ""
  sensitive   = true
}

variable "anthropic_auth_key" {
  description = "Legacy Anthropic setup-token for Claude Code style auth flows. Optional and not recommended for normal cloud-claw setup; prefer anthropic_api_key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openai_api_key" {
  description = "OpenAI API key for direct OpenAI Platform models such as openai/*."
  type        = string
  default     = ""
  sensitive   = true
}

variable "openai_codex_auth_json_base64" {
  description = "Base64-encoded contents of ~/.codex/auth.json for subscription-backed openai-codex/* models. Leave blank unless you want to import an existing Codex CLI login."
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
