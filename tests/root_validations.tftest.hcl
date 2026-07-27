override_module {
  target = module.aws
  outputs = {
    instance_public_ip = "203.0.113.10"
    instance_id        = "i-validation-aws"
    ebs_volume_id      = "vol-validation-aws"
    ssh_command        = "ssh admin@203.0.113.10"
  }
}

override_module {
  target = module.digitalocean
  outputs = {
    instance_public_ip = "203.0.113.20"
    droplet_id         = 4242
    volume_name        = "agent-stack-data"
    volume_id          = "do-volume-validation"
    ssh_command        = "ssh admin@203.0.113.20"
  }
}

override_module {
  target = module.hetzner
  outputs = {
    instance_public_ip = "203.0.113.30"
    server_id          = 31337
    volume_id          = "31338"
    ssh_command        = "ssh admin@203.0.113.30"
  }
}

variables {
  project_name                  = "agent-stack"
  admin_password                = ""
  admin_password_ssh_scope      = "disabled"
  ssh_public_key                = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAgentStackTerraformPlanTestsOnly agent-stack-tests"
  repo_ssh_private_key_path     = "tests/fixtures/fake_ssh_private_key.txt"
  generate_repo_ssh_config      = false
  aws_access_key                = "AKIAAGENTSTACKTESTS"
  aws_secret_key                = "agent-stack-tests"
  do_token                      = "do-agent-stack-tests"
  hcloud_token                  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  model_providers_enabled       = ["google"]
  default_model                 = "google/gemini-3-flash-preview"
  fallback_models               = []
  gemini_api_key                = "gemini-agent-stack-tests"
  gateway_token                 = "gateway-token-agent-stack-tests"
  hermes_api_server_key         = "hermes-key-agent-stack-tests"
  n8n_encryption_key            = "n8n-key-agent-stack-tests"
  postgres_password             = "postgres-password-agent-stack-tests"
  ui_auth_password              = "ui-password-agent-stack-tests"
  enabled_services              = ["openclaw", "hermes", "n8n"]
  tailscale_enabled             = false
  tailscale_auth_key            = ""
  openai_codex_auth_json_base64 = ""
}

run "rejects_unknown_cloud_provider" {
  command = plan

  variables {
    cloud_provider = "azure"
  }

  expect_failures = [
    var.cloud_provider,
  ]
}

run "rejects_root_admin_user" {
  command = plan

  variables {
    admin_username = "root"
  }

  expect_failures = [
    var.admin_username,
  ]
}

run "rejects_tailscale_without_auth_key" {
  command = plan

  variables {
    tailscale_enabled  = true
    tailscale_auth_key = ""
  }

  expect_failures = [
    var.tailscale_auth_key,
  ]
}

run "rejects_vpn_without_config_url" {
  command = plan

  variables {
    vpn_enabled      = true
    vpn_username     = "nord-service-user"
    vpn_password     = "nord-service-password"
    vpn_bypass_cidrs = ["203.0.113.5/32"]
  }

  expect_failures = [
    var.vpn_openvpn_config_url,
  ]
}

run "rejects_vpn_without_credentials" {
  command = plan

  variables {
    vpn_enabled            = true
    vpn_openvpn_config_url = "https://downloads.nordcdn.com/configs/files/ovpn_udp/servers/us0000.nordvpn.com.udp.ovpn"
    vpn_bypass_cidrs       = ["203.0.113.5/32"]
  }

  expect_failures = [
    var.vpn_username,
    var.vpn_password,
  ]
}

run "rejects_vpn_without_bypass_cidrs" {
  command = plan

  variables {
    vpn_enabled            = true
    vpn_openvpn_config_url = "https://downloads.nordcdn.com/configs/files/ovpn_udp/servers/us0000.nordvpn.com.udp.ovpn"
    vpn_username           = "nord-service-user"
    vpn_password           = "nord-service-password"
  }

  expect_failures = [
    var.vpn_bypass_cidrs,
  ]
}

run "rejects_vpn_non_cidr_bypass" {
  command = plan

  variables {
    vpn_bypass_cidrs = ["203.0.113.5"]
  }

  expect_failures = [
    var.vpn_bypass_cidrs,
  ]
}

run "rejects_admin_password_without_scope" {
  command = plan

  variables {
    admin_password = "agent-stack-admin-password-tests"
  }

  expect_failures = [
    var.admin_password_ssh_scope,
  ]
}

run "rejects_weak_admin_password" {
  command = plan

  variables {
    admin_password           = "short"
    admin_password_ssh_scope = "public"
    allowed_ssh_cidr         = "203.0.113.5/32"
  }

  expect_failures = [
    var.admin_password,
  ]
}

run "rejects_tailnet_admin_password_without_host_tailscale" {
  command = plan

  variables {
    admin_password           = "agent-stack-admin-password-tests"
    admin_password_ssh_scope = "tailnet"
    tailscale_enabled        = true
    tailscale_mode           = "sidecar"
    tailscale_auth_key       = "tskey-auth-agent-stack-tests"
  }

  expect_failures = [
    var.admin_password_ssh_scope,
  ]
}

run "rejects_public_admin_password_with_open_ssh_cidr" {
  command = plan

  variables {
    admin_password           = "agent-stack-admin-password-tests"
    admin_password_ssh_scope = "public"
    allowed_ssh_cidr         = "0.0.0.0/0"
  }

  expect_failures = [
    var.admin_password_ssh_scope,
  ]
}

run "rejects_public_domain_without_domains" {
  command = plan

  variables {
    public_domain_enabled = true
  }

  expect_failures = [
    terraform_data.input_validation,
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

run "rejects_digitalocean_existing_volume_without_name" {
  command = plan

  variables {
    do_existing_volume_id = "do-volume-without-name"
  }

  expect_failures = [
    var.do_existing_volume_id,
  ]
}

run "rejects_empty_model_providers" {
  command = plan

  variables {
    model_providers_enabled = []
  }

  expect_failures = [
    var.model_providers_enabled,
  ]
}

run "rejects_empty_default_model" {
  command = plan

  variables {
    default_model = ""
  }

  expect_failures = [
    var.default_model,
  ]
}

run "rejects_invalid_enabled_service" {
  command = plan

  variables {
    enabled_services = ["openclaw", "redis"]
  }

  expect_failures = [
    var.enabled_services,
  ]
}

run "rejects_workspace_without_password" {
  command = plan

  variables {
    enabled_services   = ["openclaw", "workspace"]
    workspace_password = ""
  }

  expect_failures = [
    var.workspace_password,
  ]
}

run "rejects_workspace_private_key_path_in_public_keys" {
  command = plan

  variables {
    workspace_ssh_public_keys = ["/Users/alice/.ssh/id_ed25519"]
  }

  expect_failures = [
    var.workspace_ssh_public_keys,
  ]
}

run "rejects_drive_fuse_without_workspace" {
  command = plan

  variables {
    workspace_drive_fuse_enabled         = true
    workspace_drive_rclone_config_base64 = "Y29uZmln"
  }

  expect_failures = [
    var.workspace_drive_fuse_enabled,
  ]
}

run "rejects_drive_fuse_without_valid_base64_config" {
  command = plan

  variables {
    enabled_services                     = ["openclaw", "workspace"]
    workspace_password                   = "workspace-password-agent-stack-tests"
    workspace_drive_fuse_enabled         = true
    workspace_drive_rclone_config_base64 = "not base64!"
  }

  expect_failures = [
    var.workspace_drive_rclone_config_base64,
  ]
}

run "rejects_invalid_tailscale_mode" {
  command = plan

  variables {
    tailscale_mode = "container"
  }

  expect_failures = [
    var.tailscale_mode,
  ]
}
