terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Locals
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Volume name used for the device symlink path on the Droplet:
  # /dev/disk/by-id/scsi-0DO_Volume_<name>
  do_volume_name = (
    var.do_existing_volume_id != ""
    ? var.do_existing_volume_name
    : "${var.project_name}-data"
  )

  do_volume_id = (
    var.do_existing_volume_id != ""
    ? var.do_existing_volume_id
    : one(digitalocean_volume.this[*].id)
  )

  cloud_init = templatefile("${path.module}/../common/templates/cloud_init.yaml.tpl", {
    provider_type                        = "digitalocean"
    project_name                         = var.project_name
    admin_username                       = var.admin_username
    admin_ssh_public_key                 = var.ssh_public_key
    ebs_volume_id                        = ""
    do_volume_name                       = local.do_volume_name
    anthropic_api_key                    = var.anthropic_api_key
    anthropic_auth_key                   = var.anthropic_auth_key
    openai_api_key                       = var.openai_api_key
    groq_api_key                         = var.groq_api_key
    gemini_api_key                       = var.gemini_api_key
    telegram_bot_token                   = var.telegram_bot_token
    telegram_allow_from_json             = jsonencode(var.telegram_allow_from)
    openclaw_config_mode                 = var.openclaw_config_mode
    agent_channel                        = var.agent_channel
    model_providers_enabled_json         = jsonencode(var.model_providers_enabled)
    default_model                        = var.default_model
    fallback_models_json                 = jsonencode(var.fallback_models)
    tailscale_enabled                    = var.tailscale_enabled
    tailscale_auth_key                   = var.tailscale_auth_key
    openclaw_version                     = var.openclaw_version
    openclaw_node_options                = var.openclaw_node_options
    openclaw_swap_size_mb                = var.openclaw_swap_size_mb
    openclaw_health_start_period_seconds = var.openclaw_health_start_period_seconds
    openclaw_health_retries              = var.openclaw_health_retries
    seed_starter_workspace_files         = var.seed_starter_workspace_files
    starter_soul_profile                 = var.starter_soul_profile
    starter_soul_balanced_md             = file("${path.module}/../common/templates/starter/SOUL.balanced.md")
    starter_soul_builder_md              = file("${path.module}/../common/templates/starter/SOUL.builder.md")
    starter_soul_researcher_md           = file("${path.module}/../common/templates/starter/SOUL.researcher.md")
    starter_agents_md                    = file("${path.module}/../common/templates/starter/AGENTS.default.md")
    starter_tools_md                     = file("${path.module}/../common/templates/starter/TOOLS.default.md")
    starter_user_md                      = file("${path.module}/../common/templates/starter/USER.default.md")
    gateway_token                        = var.gateway_token
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH key
# ─────────────────────────────────────────────────────────────────────────────

resource "digitalocean_ssh_key" "this" {
  name       = "${var.project_name}-key"
  public_key = var.ssh_public_key
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────────────────────────────────────

resource "digitalocean_vpc" "this" {
  name     = "${var.project_name}-vpc"
  region   = var.do_region
  ip_range = "10.1.0.0/16"
}

# ─────────────────────────────────────────────────────────────────────────────
# Block storage volume (portable — survives Droplet deletion)
# ─────────────────────────────────────────────────────────────────────────────

resource "digitalocean_volume" "this" {
  count  = var.do_existing_volume_id == "" ? 1 : 0
  region = var.do_region
  name   = local.do_volume_name
  size   = var.do_disk_size_gb

  # Let cloud-init handle formatting so we can control mount path.
  # (Setting initial_filesystem_type triggers DO auto-mount which we'd have
  # to undo; leaving it blank means we format + mount in the bootstrap script.)
  initial_filesystem_type  = null
  initial_filesystem_label = null

  tags = [var.project_name]
}

# ─────────────────────────────────────────────────────────────────────────────
# Droplet
# ─────────────────────────────────────────────────────────────────────────────

resource "digitalocean_droplet" "this" {
  name     = var.project_name
  region   = var.do_region
  size     = var.do_droplet_size
  image    = "ubuntu-22-04-x64"
  vpc_uuid = digitalocean_vpc.this.id
  ssh_keys = [digitalocean_ssh_key.this.id]

  user_data = local.cloud_init

  # Ensure volume is created before Droplet so the bootstrap can find it
  depends_on = [digitalocean_volume.this]

  tags = [var.project_name]
}

# ─────────────────────────────────────────────────────────────────────────────
# Attach volume to Droplet
# ─────────────────────────────────────────────────────────────────────────────

resource "digitalocean_volume_attachment" "this" {
  droplet_id = digitalocean_droplet.this.id
  volume_id  = local.do_volume_id
}

# ─────────────────────────────────────────────────────────────────────────────
# Firewall — SSH only + Tailscale UDP (if enabled)
# ─────────────────────────────────────────────────────────────────────────────

resource "digitalocean_firewall" "this" {
  name        = "${var.project_name}-fw"
  droplet_ids = [digitalocean_droplet.this.id]

  # SSH
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.allowed_ssh_cidr]
  }

  # Tailscale (conditional)
  dynamic "inbound_rule" {
    for_each = var.tailscale_enabled ? [1] : []
    content {
      protocol         = "udp"
      port_range       = "41641"
      source_addresses = ["0.0.0.0/0", "::/0"]
    }
  }

  # Outbound — unrestricted (needed for Docker pulls, Tailscale, package updates)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
