override_module {
  target = module.aws
  outputs = {
    instance_public_ip = "203.0.113.10"
    instance_id        = "i-provider-matrix-aws"
    ebs_volume_id      = "vol-provider-matrix-aws"
    ssh_command        = "ssh admin@203.0.113.10"
  }
}

override_module {
  target = module.digitalocean
  outputs = {
    instance_public_ip = "203.0.113.20"
    droplet_id         = 4242
    volume_name        = "agent-stack-data"
    volume_id          = "do-volume-provider-matrix"
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
  project_name                                   = "agent-stack"
  admin_ssh_host_override                        = ""
  workspace_ssh_host_override                    = ""
  admin_password                                 = ""
  admin_password_ssh_scope                       = "disabled"
  ssh_public_key                                 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAgentStackTerraformPlanTestsOnly agent-stack-tests"
  repo_ssh_private_key_path                      = "tests/fixtures/fake_ssh_private_key.txt"
  generate_repo_ssh_config                       = false
  aws_access_key                                 = "AKIAAGENTSTACKTESTS"
  aws_secret_key                                 = "agent-stack-tests"
  do_token                                       = "do-agent-stack-tests"
  hcloud_token                                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  model_providers_enabled                        = ["google"]
  default_model                                  = "google/gemini-3-flash-preview"
  fallback_models                                = []
  gemini_api_key                                 = "gemini-agent-stack-tests"
  gateway_token                                  = "gateway-token-agent-stack-tests"
  hermes_api_server_key                          = "hermes-key-agent-stack-tests"
  n8n_encryption_key                             = "n8n-key-agent-stack-tests"
  postgres_password                              = "postgres-password-agent-stack-tests"
  ui_auth_password                               = "ui-password-agent-stack-tests"
  enabled_services                               = ["openclaw", "hermes", "n8n"]
  workspace_codex_release                        = "0.145.0"
  workspace_codex_auto_update_enabled            = false
  workspace_codex_auto_update_timezone           = "America/New_York"
  workspace_codex_auto_update_time               = "04:00"
  workspace_codex_auto_recover_interrupted_turns = false
  vpn_enabled                                    = false
  vpn_provider                                   = "nordvpn_openvpn"
  vpn_nordvpn_token                              = ""
  vpn_nordvpn_connect_target                     = ""
  vpn_openvpn_config_url                         = ""
  vpn_username                                   = ""
  vpn_password                                   = ""
  vpn_bypass_cidrs                               = []
  tailscale_enabled                              = true
  tailscale_auth_key                             = "tskey-auth-agent-stack-tests"
  openai_codex_auth_json_base64                  = ""
}

run "aws_provider_matrix" {
  command   = plan
  state_key = "aws-provider-matrix"

  variables {
    cloud_provider = "aws"
  }

  assert {
    condition     = output.provider_used == "aws"
    error_message = "Root module should report AWS as the selected provider."
  }

  assert {
    condition     = output.instance_public_ip == "203.0.113.10"
    error_message = "AWS selection should read the AWS module public IP."
  }

  assert {
    condition     = terraform_data.runtime_apply.triggers_replace.instance_id == "i-provider-matrix-aws"
    error_message = "Runtime replacement triggers should include the selected AWS instance ID."
  }

  assert {
    condition     = terraform_data.runtime_apply.triggers_replace.volume_id == "vol-provider-matrix-aws"
    error_message = "Runtime replacement triggers should include the selected AWS data volume ID."
  }
}

run "digitalocean_provider_matrix" {
  command   = plan
  state_key = "digitalocean-provider-matrix"

  variables {
    cloud_provider = "digitalocean"
  }

  assert {
    condition     = output.provider_used == "digitalocean"
    error_message = "Root module should report DigitalOcean as the selected provider."
  }

  assert {
    condition     = output.instance_public_ip == "203.0.113.20"
    error_message = "DigitalOcean selection should read the DigitalOcean module public IP."
  }

  assert {
    condition     = terraform_data.runtime_apply.triggers_replace.instance_id == 4242
    error_message = "Runtime replacement triggers should include the selected Droplet ID."
  }

  assert {
    condition     = terraform_data.runtime_apply.triggers_replace.volume_id == "do-volume-provider-matrix"
    error_message = "Runtime replacement triggers should include the selected DigitalOcean volume ID."
  }
}

run "hetzner_provider_matrix" {
  command   = plan
  state_key = "hetzner-provider-matrix"

  variables {
    cloud_provider = "hetzner"
  }

  assert {
    condition     = output.provider_used == "hetzner"
    error_message = "Root module should report Hetzner as the selected provider."
  }

  assert {
    condition     = output.instance_public_ip == "203.0.113.30"
    error_message = "Hetzner selection should read the Hetzner module public IP."
  }

  assert {
    condition     = terraform_data.runtime_apply.triggers_replace.instance_id == 31337
    error_message = "Runtime replacement triggers should include the selected Hetzner server ID."
  }

  assert {
    condition     = terraform_data.runtime_apply.triggers_replace.volume_id == "31338"
    error_message = "Runtime replacement triggers should include the selected Hetzner volume ID."
  }
}
