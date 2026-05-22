mock_provider "aws" {
  override_during = plan

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a"]
    }
  }

  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      id        = "i-0123456789abcdef0"
      public_ip = "203.0.113.10"
    }
  }

  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0123456789abcdef0"
    }
  }
}

mock_provider "digitalocean" {
  override_during = plan

  mock_resource "digitalocean_droplet" {
    defaults = {
      id           = "10001"
      ipv4_address = "203.0.113.20"
    }
  }

  mock_resource "digitalocean_volume" {
    defaults = {
      id = "do-volume-0001"
    }
  }
}

mock_provider "hcloud" {
  override_during = plan

  mock_resource "hcloud_server" {
    defaults = {
      id           = 20001
      ipv4_address = "203.0.113.30"
    }
  }

  mock_resource "hcloud_volume" {
    defaults = {
      id = 30001
    }
  }
}

mock_provider "local" {
  override_during = plan
}

mock_provider "external" {
  override_during = plan
}

mock_provider "random" {
  override_during = plan

  mock_resource "random_password" {
    defaults = {
      result = "offlineGeneratedSecret1234567890"
    }
  }
}

variables {
  ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOfflineTerraformTestKey000000000000000 test@example"
  generate_repo_ssh_config = false
  model_providers_enabled  = ["google"]
  default_model            = "google/gemini-3-flash-preview"
  fallback_models          = []
  tailscale_enabled        = false
}

run "aws_all_services_local_postgres" {
  command   = plan
  state_key = "aws_all_services_local_postgres"

  variables {
    cloud_provider = "aws"
  }

  assert {
    condition     = output.provider_used == "aws"
    error_message = "AWS matrix case should report aws as provider_used."
  }

  assert {
    condition     = output.openclaw_url != "disabled" && output.hermes_url != "disabled" && output.n8n_url != "disabled"
    error_message = "All default services should be enabled."
  }

  assert {
    condition     = output.repo_ssh_config_path == "disabled"
    error_message = "Offline tests must not write repo-local SSH config."
  }
}

run "digitalocean_openclaw_only" {
  command   = plan
  state_key = "digitalocean_openclaw_only"

  variables {
    cloud_provider   = "digitalocean"
    enabled_services = ["openclaw"]
  }

  assert {
    condition     = output.provider_used == "digitalocean"
    error_message = "DigitalOcean matrix case should report digitalocean as provider_used."
  }

  assert {
    condition     = output.openclaw_url != "disabled" && output.hermes_url == "disabled" && output.n8n_url == "disabled"
    error_message = "OpenClaw-only case should disable Hermes and n8n URLs."
  }
}

run "hetzner_all_services_local_postgres" {
  command   = plan
  state_key = "hetzner_all_services_local_postgres"

  variables {
    cloud_provider = "hetzner"
  }

  assert {
    condition     = output.provider_used == "hetzner"
    error_message = "Hetzner matrix case should report hetzner as provider_used."
  }

  assert {
    condition     = output.openclaw_url != "disabled" && output.hermes_url != "disabled" && output.n8n_url != "disabled"
    error_message = "Hetzner all-services case should enable all service URLs."
  }
}

run "aws_all_services_external_postgres" {
  command   = plan
  state_key = "aws_all_services_external_postgres"

  variables {
    cloud_provider                = "aws"
    n8n_database_mode             = "external_postgres"
    external_postgres_host        = "db.internal.example"
    external_postgres_database    = "n8n"
    external_postgres_user        = "n8n"
    external_postgres_password    = "external-postgres-password"
    external_postgres_ssl_enabled = true
  }

  assert {
    condition     = output.n8n_url != "disabled"
    error_message = "External Postgres mode should still enable n8n."
  }
}

run "digitalocean_public_domain_from_base_domain" {
  command   = plan
  state_key = "digitalocean_public_domain_from_base_domain"

  variables {
    cloud_provider        = "digitalocean"
    public_domain_enabled = true
    base_domain           = "example.com"
  }

  assert {
    condition     = output.openclaw_url == "https://openclaw.example.com" && output.hermes_url == "https://hermes.example.com" && output.n8n_url == "https://n8n.example.com"
    error_message = "Base domain should derive service domains."
  }

  assert {
    condition     = output.ui_auth_username == "admin"
    error_message = "Public-domain auth username should use the default admin username."
  }
}

run "hetzner_public_domain_explicit_domains" {
  command   = plan
  state_key = "hetzner_public_domain_explicit_domains"

  variables {
    cloud_provider        = "hetzner"
    public_domain_enabled = true
    openclaw_domain       = "claw.example.net"
    hermes_domain         = "hermes.example.net"
    n8n_domain            = "n8n.example.net"
  }

  assert {
    condition     = output.openclaw_url == "https://claw.example.net" && output.hermes_url == "https://hermes.example.net" && output.n8n_webhook_url == "https://n8n.example.net/webhook"
    error_message = "Explicit domains should control service URLs."
  }
}

run "aws_existing_volume" {
  command   = plan
  state_key = "aws_existing_volume"

  variables {
    cloud_provider         = "aws"
    aws_existing_volume_id = "vol-0abc123def4567890"
    openclaw_config_mode   = "auto"
  }

  assert {
    condition     = module.aws[0].ebs_volume_id == "vol-0abc123def4567890"
    error_message = "AWS existing-volume case should use the provided EBS volume ID."
  }
}

run "digitalocean_existing_volume" {
  command   = plan
  state_key = "digitalocean_existing_volume"

  variables {
    cloud_provider          = "digitalocean"
    do_existing_volume_id   = "do-volume-existing-001"
    do_existing_volume_name = "agent-stack-data"
    openclaw_config_mode    = "auto"
  }

  assert {
    condition     = module.digitalocean[0].volume_name == "agent-stack-data"
    error_message = "DigitalOcean existing-volume case should preserve the provided volume name."
  }
}

run "hetzner_existing_volume" {
  command   = plan
  state_key = "hetzner_existing_volume"

  variables {
    cloud_provider            = "hetzner"
    hcloud_existing_volume_id = "30099"
    openclaw_config_mode      = "auto"
  }

  assert {
    condition     = tostring(module.hetzner[0].volume_id) == "30099"
    error_message = "Hetzner existing-volume case should use the provided volume ID."
  }
}
