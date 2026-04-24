# SSH and Runtime Runbook

## Security notes

- Do not store secrets in docs or logs.
- Treat `terraform.tfvars`, `*.tfstate`, `gateway_token`, and `#token=` URLs as sensitive.

## Preferred local entrypoints

- SSH wrapper: `bin/cloud-claw-ssh`
- Run remote commands: `bin/cloud-claw-ssh -- <command>`
- Clean stale local SSH sessions: `bin/cloud-claw-ssh-clean`
- Local diagnostics: `skills/claw-doctor/scripts/collect_diagnostics.sh`
  - This redacts token-bearing Terraform outputs by default.
  - Use `skills/claw-doctor/scripts/collect_diagnostics.sh --show-secrets` only when you intentionally need the raw values.

## Useful Terraform outputs

```bash
terraform output -raw repo_ssh_command
terraform output -raw ssh_command
terraform output -raw bootstrap_log_command
terraform output -raw repo_bootstrap_log_command
terraform output -raw dashboard_url
terraform output -raw dashboard_url_with_token_import
```

## Important remote paths

- App root: `/opt/openclaw`
- Compose file: `/opt/openclaw/docker-compose.yml`
- Env file: `/opt/openclaw/.env`
- Data/config volume: `/opt/openclaw/data`
- Workspace volume: `/opt/openclaw/data/workspace`
- Bootstrap log: `/var/log/openclaw-bootstrap.log`

## Fast health checks

```bash
bin/cloud-claw-ssh -- sudo systemctl status --no-pager openclaw
bin/cloud-claw-ssh -- sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
bin/cloud-claw-ssh -- curl -sv --max-time 5 http://127.0.0.1:18789/ 2>&1 | sed -n '1,40p'
```

To inspect the app container after you discover its name:

```bash
bin/cloud-claw-ssh -- sudo docker exec <app_container> openclaw health --json
bin/cloud-claw-ssh -- sudo docker inspect --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restartCount={{.RestartCount}} started={{.State.StartedAt}}' <app_container>
bin/cloud-claw-ssh -- sudo docker logs --since 20m <app_container> | tail -n 200
```

## Tailscale checks

```bash
bin/cloud-claw-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock status --json | jq -r '.Self.Online, .Self.DNSName, (.Health[]? // empty)'
bin/cloud-claw-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock serve status
bin/cloud-claw-ssh -- sudo docker exec <tailscale_container> sh -lc 'wget -S -O /dev/null -T 5 http://127.0.0.1:18789 2>&1 | sed -n "1,40p"'
```

Expected secure pattern:

- `OPENCLAW_GATEWAY_BIND=loopback`
- Tailscale sidecar uses `network_mode: "service:openclaw"`
- `tailscale serve` forwards to `127.0.0.1:18789`

## Recovery commands

```bash
bin/cloud-claw-ssh -- sudo systemctl restart openclaw
bin/cloud-claw-ssh -- sudo docker restart <tailscale_container>
bin/cloud-claw-ssh -- systemctl status --no-pager openclaw-tailscale-watchdog.timer
```

## Pairing commands

```bash
bin/cloud-claw-ssh -- sudo docker exec openclaw-openclaw-1 openclaw devices list
bin/cloud-claw-ssh -- sudo docker exec openclaw-openclaw-1 openclaw devices approve <requestId>
```
