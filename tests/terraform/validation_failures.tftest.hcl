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
}

mock_provider "digitalocean" {
  override_during = plan
}

mock_provider "hcloud" {
  override_during = plan
}

mock_provider "local" {
  override_during = plan
}

mock_provider "external" {
  override_during = plan
}

mock_provider "random" {
  override_during = plan
}

variables {
  cloud_provider           = "aws"
  ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOfflineTerraformTestKey000000000000000 test@example"
  generate_repo_ssh_config = false
  model_providers_enabled  = ["google"]
  default_model            = "google/gemini-3-flash-preview"
  fallback_models          = []
  tailscale_enabled        = false
}

run "rejects_invalid_cloud_provider" {
  command = plan

  variables {
    cloud_provider = "gcp"
  }

  expect_failures = [
    var.cloud_provider,
  ]
}

run "rejects_empty_enabled_services" {
  command = plan

  variables {
    enabled_services = []
  }

  expect_failures = [
    var.enabled_services,
  ]
}

run "rejects_unknown_enabled_service" {
  command = plan

  variables {
    enabled_services = ["openclaw", "airflow"]
  }

  expect_failures = [
    var.enabled_services,
  ]
}

run "rejects_invalid_n8n_database_mode" {
  command = plan

  variables {
    n8n_database_mode = "sqlite"
  }

  expect_failures = [
    var.n8n_database_mode,
  ]
}

run "rejects_external_postgres_without_connection_values" {
  command = plan

  variables {
    n8n_database_mode = "external_postgres"
  }

  expect_failures = [
    terraform_data.input_validation,
  ]
}

run "rejects_public_domain_without_any_domains" {
  command = plan

  variables {
    public_domain_enabled = true
  }

  expect_failures = [
    terraform_data.input_validation,
  ]
}

run "rejects_unsupported_ui_auth_mode" {
  command = plan

  variables {
    public_domain_enabled = true
    base_domain           = "example.com"
    ui_auth_mode          = "oauth"
  }

  expect_failures = [
    var.ui_auth_mode,
  ]
}

run "rejects_tailscale_enabled_without_auth_key" {
  command = plan

  variables {
    tailscale_enabled  = true
    tailscale_auth_key = ""
  }

  expect_failures = [
    var.tailscale_auth_key,
  ]
}
