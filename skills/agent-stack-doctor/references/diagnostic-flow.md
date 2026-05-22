# Diagnostic Flow

Follow this order to keep repairs deliberate and explainable.

## 1. Local Terraform and access baseline

- Confirm `terraform` works in the repo.
- Confirm `terraform output` is available and note `provider_used`, `instance_public_ip`, `ssh_command`, and `repo_ssh_command`.
- Confirm the repo-local SSH assets exist: `bin/agent-stack-ssh`, `bin/agent-stack-ssh-clean`, `.ssh/config`, and the expected private key.

If Terraform outputs are missing or stale, stop and diagnose the local deployment state before assuming the remote instance is healthy.

## 2. SSH and bootstrap reachability

- If SSH fails, check the wrapper, the private key path, the instance IP, and `allowed_ssh_cidr`.
- If SSH succeeds, inspect `/var/log/openclaw-bootstrap.log`, `agent-stack.service`, and Docker container status first.
- Check whether `/opt/agent-stack` exists. If it does not, fall back to `/opt/openclaw` and diagnose the instance as a legacy OpenClaw-only deployment.
- If both `/opt/agent-stack` and `/opt/openclaw` exist but `/opt/openclaw` is not a symlink, flag a partial layout migration and recommend rerunning `/usr/local/bin/agent-stack-migrate-layout`.

## 3. Runtime health

- Confirm the OpenClaw container exists and is healthy.
- Confirm selected Hermes, n8n, Postgres, and Caddy containers exist when their services are enabled.
- Check `http://127.0.0.1:18789/healthz` on the VM.
- Check Hermes on `http://127.0.0.1:9119` and n8n on `http://127.0.0.1:5678/healthz` when enabled.
- Inspect recent container logs and restart counts.

## 4. Tailscale, domains, and UI access

- If Tailscale is enabled, confirm the sidecar is online.
- Check `tailscale serve status`.
- If public domains are enabled, confirm DNS points at the instance IP and inspect Caddy logs.
- If the UI loads but rejects requests, inspect `gateway.controlUi.allowedOrigins` and the token-import URL from Terraform outputs.

## 5. Channel and pairing issues

- For Telegram, verify `telegram_bot_token` and `telegram_allow_from`.
- For WhatsApp, verify plugin enablement and QR login state.
- For pairing problems, inspect pending device approvals and use the pairing commands from Terraform outputs.

## 6. Model and provider issues

- Confirm the selected providers have matching credentials in `/opt/agent-stack/.env`, falling back to `/opt/openclaw/.env` only for legacy installs.
- Confirm `model_providers_enabled`, `default_model`, and `fallback_models` still match the intended deployment.
- Treat the Anthropic auth-key mismatch as a first-class diagnosis: current bootstrap needs `anthropic_auth_key` when Anthropic is selected.
