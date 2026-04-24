# Verification and Recovery

Use this after `terraform apply` and during setup-time troubleshooting.

## Immediate checks

- `terraform output -raw provider_used`
- `terraform output -raw instance_public_ip`
- `terraform output -raw ssh_command`
- `terraform output -raw repo_ssh_command`
- `terraform output -raw dashboard_url`
- `terraform output -raw dashboard_url_with_token_import`
- `terraform output -raw bootstrap_log_command`
- `terraform output -raw repo_bootstrap_log_command`

## Bootstrap checks

- Watch the bootstrap log: `bin/cloud-claw-ssh -- tail -f /var/log/openclaw-bootstrap.log`
- Check the service: `bin/cloud-claw-ssh -- sudo systemctl status --no-pager openclaw`
- Check containers: `bin/cloud-claw-ssh -- sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'`
- Check the local gateway on the VM: `bin/cloud-claw-ssh -- curl -sv --max-time 5 http://127.0.0.1:18789/healthz`

## Tailscale checks

- Read `terraform output -raw tailscale_note`
- If Tailscale is enabled, confirm the sidecar is online and serving the dashboard:
  - `bin/cloud-claw-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock status --json`
  - `bin/cloud-claw-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock serve status`

## Common setup-time failures

- Apply failed before instance creation:
  - re-check provider credentials, region, and required model-routing values
- Apply succeeded but bootstrap is stuck:
  - inspect `/var/log/openclaw-bootstrap.log`
  - check for hung plugin commands or missing Tailscale auth
- Dashboard URL does not load:
  - verify OpenClaw health on `127.0.0.1:18789`
  - verify Tailscale sidecar status and serve configuration

If the issue becomes a general diagnosis or repair problem rather than a setup problem, switch to `skills/claw-doctor/SKILL.md`.
