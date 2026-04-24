# Diagnostic Flow

Follow this order to keep repairs deliberate and explainable.

## 1. Local Terraform and access baseline

- Confirm `terraform` works in the repo.
- Confirm `terraform output` is available and note `provider_used`, `instance_public_ip`, `ssh_command`, and `repo_ssh_command`.
- Confirm the repo-local SSH assets exist: `bin/cloud-claw-ssh`, `bin/cloud-claw-ssh-clean`, `.ssh/config`, and the expected private key.

If Terraform outputs are missing or stale, stop and diagnose the local deployment state before assuming the remote instance is healthy.

## 2. SSH and bootstrap reachability

- If SSH fails, check the wrapper, the private key path, the instance IP, and `allowed_ssh_cidr`.
- If SSH succeeds, inspect `/var/log/openclaw-bootstrap.log`, `openclaw.service`, and Docker container status first.

## 3. Runtime health

- Confirm the OpenClaw container exists and is healthy.
- Check `http://127.0.0.1:18789/healthz` on the VM.
- Inspect recent OpenClaw container logs and restart counts.

## 4. Tailscale and dashboard access

- If Tailscale is enabled, confirm the sidecar is online.
- Check `tailscale serve status`.
- If the UI loads but rejects requests, inspect `gateway.controlUi.allowedOrigins` and the token-import URL from Terraform outputs.

## 5. Channel and pairing issues

- For Telegram, verify `telegram_bot_token` and `telegram_allow_from`.
- For WhatsApp, verify plugin enablement and QR login state.
- For pairing problems, inspect pending device approvals and use the pairing commands from Terraform outputs.

## 6. Model and provider issues

- Confirm the selected providers have matching credentials in `/opt/openclaw/.env`.
- Confirm `model_providers_enabled`, `default_model`, and `fallback_models` still match the intended deployment.
- Treat the Anthropic auth-key mismatch as a first-class diagnosis: current bootstrap needs `anthropic_auth_key` when Anthropic is selected.
