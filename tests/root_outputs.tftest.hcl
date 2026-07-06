override_module {
  target = module.aws
  outputs = {
    instance_public_ip = "203.0.113.10"
    instance_id        = "i-root-output-aws"
    ebs_volume_id      = "vol-root-output-aws"
    ssh_command        = "ssh admin@203.0.113.10"
  }
}

override_module {
  target = module.digitalocean
  outputs = {
    instance_public_ip = "203.0.113.20"
    droplet_id         = 4242
    volume_name        = "agent-stack-data"
    volume_id          = "do-volume-root-output"
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
  tailscale_enabled             = true
  tailscale_mode                = "sidecar"
  tailscale_auth_key            = "tskey-auth-agent-stack-tests"
  openai_codex_auth_json_base64 = ""
}

run "tailscale_private_outputs" {
  command   = plan
  state_key = "tailscale-private-outputs"

  variables {
    cloud_provider = "aws"
  }

  assert {
    condition     = strcontains(output.dashboard_url, "https://agent-stack") && strcontains(output.dashboard_url, "mode=sidecar")
    error_message = "Private Tailscale dashboard URL should point at the AgentStack Tailscale Serve name."
  }

  assert {
    condition     = output.dashboard_url_with_token_import == "https://agent-stack/#token=gateway-token-agent-stack-tests"
    error_message = "Token import URL should use the explicit gateway token during tests."
  }

  assert {
    condition     = strcontains(output.tailscale_note, "Tailscale is enabled in sidecar mode.")
    error_message = "Tailscale-enabled deployments should surface the Tailscale handoff note."
  }

  assert {
    condition     = output.host_codex_login_command == "ssh admin@203.0.113.10 'codex login --device-auth'"
    error_message = "Host Codex login command should use the admin SSH target and device auth."
  }
}

run "workspace_host_outputs" {
  command   = plan
  state_key = "workspace-host-outputs"

  variables {
    cloud_provider          = "hetzner"
    enabled_services        = ["openclaw", "workspace"]
    workspace_username      = "ferrerluis"
    workspace_password      = "workspace-password-agent-stack-tests"
    workspace_ssh_host_port = 2222
    tailscale_mode          = "host"
  }

  assert {
    condition     = output.workspace_ssh_command == "ssh -p 2222 ferrerluis@agent-stack"
    error_message = "Workspace SSH command should use the configured username, host port, and Tailscale device name."
  }

  assert {
    condition     = output.workspace_codex_login_command == "ssh -p 2222 ferrerluis@agent-stack 'codex login --device-auth'"
    error_message = "Workspace Codex login command should use device auth inside the workspace."
  }

  assert {
    condition     = strcontains(output.workspace_note, "no Docker socket is mounted") && !strcontains(output.workspace_note, "workspace-password-agent-stack-tests")
    error_message = "Workspace note should describe the safety boundary without exposing the workspace password."
  }

  assert {
    condition     = strcontains(output.dashboard_url, "mode=host")
    error_message = "Host Tailscale mode should be visible in access outputs."
  }
}

run "public_domain_outputs" {
  command   = plan
  state_key = "public-domain-outputs"

  variables {
    cloud_provider        = "digitalocean"
    public_domain_enabled = true
    base_domain           = "example.com"
    tailscale_enabled     = false
    tailscale_auth_key    = ""
  }

  assert {
    condition     = output.openclaw_url == "https://openclaw.example.com"
    error_message = "OpenClaw public URL should derive from base_domain."
  }

  assert {
    condition     = output.hermes_url == "https://hermes.example.com"
    error_message = "Hermes public URL should derive from base_domain."
  }

  assert {
    condition     = output.n8n_webhook_url == "https://n8n.example.com/webhook"
    error_message = "n8n webhook public URL should derive from base_domain."
  }

  assert {
    condition     = output.ui_auth_username == "admin"
    error_message = "Public-domain deployments should expose the configured UI auth username."
  }
}

run "disabled_service_outputs" {
  command   = plan
  state_key = "disabled-service-outputs"

  variables {
    cloud_provider   = "hetzner"
    enabled_services = ["hermes"]
  }

  assert {
    condition     = output.dashboard_url == "disabled"
    error_message = "OpenClaw dashboard should be disabled when OpenClaw is not enabled."
  }

  assert {
    condition     = output.n8n_url == "disabled"
    error_message = "n8n URL should be disabled when n8n is not enabled."
  }

  assert {
    condition     = output.pair_latest_command == "disabled"
    error_message = "Pairing command should be disabled when OpenClaw is not enabled."
  }

  assert {
    condition     = strcontains(output.tailscale_note, "OpenClaw is disabled")
    error_message = "Tailscale note should call out that no OpenClaw Serve route is configured."
  }
}
