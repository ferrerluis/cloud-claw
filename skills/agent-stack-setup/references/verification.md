# Verification and Recovery

Use this after `terraform apply` and during setup-time troubleshooting.

## Immediate checks

- `terraform output -raw provider_used`
- `terraform output -raw instance_public_ip`
- `terraform output -raw ssh_command`
- `terraform output -raw repo_ssh_command`
- `terraform output -raw dashboard_url`
- `terraform output -raw dashboard_url_with_token_import`
- `terraform output -raw openclaw_url`
- `terraform output -raw hermes_url`
- `terraform output -raw n8n_url`
- `terraform output -raw n8n_webhook_url`
- `terraform output -raw bootstrap_log_command`
- `terraform output -raw repo_bootstrap_log_command`

## Bootstrap checks

- Watch the bootstrap log: `bin/agent-stack-ssh -- tail -f /var/log/openclaw-bootstrap.log`
- Check the service: `bin/agent-stack-ssh -- sudo systemctl status --no-pager agent-stack`
- Check containers: `bin/agent-stack-ssh -- sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'`
- Check selected local services on the VM:
  - OpenClaw: `bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:18789/healthz`
  - Hermes: `bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:9119`
  - n8n: `bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:5678/healthz`

## Tailscale checks

- Read `terraform output -raw tailscale_note`
- If Tailscale is enabled, confirm the sidecar is online and serving the dashboard:
  - `bin/agent-stack-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock status --json`
  - `bin/agent-stack-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock serve status`

## Common setup-time failures

- Apply failed before instance creation:
  - re-check provider credentials, region, and required model-routing values
- Apply succeeded but bootstrap is stuck:
  - inspect `/var/log/openclaw-bootstrap.log`
  - check for hung plugin commands or missing Tailscale auth
- UI URL does not load:
  - verify OpenClaw health on `127.0.0.1:18789`
  - verify Hermes or n8n local ports if those services are enabled
  - verify Caddy logs if public domains are enabled
  - verify Tailscale sidecar status and serve configuration

If the issue becomes a general diagnosis or repair problem rather than a setup problem, switch to `skills/agent-stack-doctor/SKILL.md`.
