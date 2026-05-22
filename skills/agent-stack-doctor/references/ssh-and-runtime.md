# SSH and Runtime Runbook

## Security notes

- Do not store secrets in docs or logs.
- Treat `terraform.tfvars`, `*.tfstate`, `gateway_token`, and `#token=` URLs as sensitive.

## Preferred local entrypoints

- SSH wrapper: `bin/agent-stack-ssh`
- Run remote commands: `bin/agent-stack-ssh -- <command>`
- Clean stale local SSH sessions: `bin/agent-stack-ssh-clean`
- Local diagnostics: `skills/agent-stack-doctor/scripts/collect_diagnostics.sh`
  - This redacts token-bearing Terraform outputs by default.
  - Use `skills/agent-stack-doctor/scripts/collect_diagnostics.sh --show-secrets` only when you intentionally need the raw values.

## Useful Terraform outputs

```bash
terraform output -raw repo_ssh_command
terraform output -raw ssh_command
terraform output -raw bootstrap_log_command
terraform output -raw repo_bootstrap_log_command
terraform output -raw dashboard_url
terraform output -raw dashboard_url_with_token_import
terraform output -raw openclaw_url
terraform output -raw hermes_url
terraform output -raw n8n_url
terraform output -raw n8n_webhook_url
```

## Important remote paths

- App root: `/opt/agent-stack`
- Compose file: `/opt/agent-stack/docker-compose.yml`
- Env file: `/opt/agent-stack/.env`
- Data root: `/opt/agent-stack/data`
- OpenClaw data: `/opt/agent-stack/data/openclaw`
- Hermes data: `/opt/agent-stack/data/hermes`
- n8n data: `/opt/agent-stack/data/n8n`
- Postgres data: `/opt/agent-stack/data/postgres`
- Caddy data: `/opt/agent-stack/data/caddy`
- Legacy compatibility root: `/opt/openclaw`
- Bootstrap log: `/var/log/openclaw-bootstrap.log`

## Fast health checks

```bash
bin/agent-stack-ssh -- sudo systemctl status --no-pager agent-stack
bin/agent-stack-ssh -- sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:18789/ 2>&1 | sed -n '1,40p'
bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:9119/ 2>&1 | sed -n '1,40p'
bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:5678/healthz 2>&1 | sed -n '1,40p'
```

To inspect the app container after you discover its name:

```bash
bin/agent-stack-ssh -- sudo docker exec <app_container> openclaw health --json
bin/agent-stack-ssh -- sudo docker inspect --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restartCount={{.RestartCount}} started={{.State.StartedAt}}' <app_container>
bin/agent-stack-ssh -- sudo docker logs --since 20m <app_container> | tail -n 200
```

## Tailscale checks

```bash
bin/agent-stack-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock status --json | jq -r '.Self.Online, .Self.DNSName, (.Health[]? // empty)'
bin/agent-stack-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock serve status
bin/agent-stack-ssh -- sudo docker exec <tailscale_container> sh -lc 'wget -S -O /dev/null -T 5 http://127.0.0.1:18789 2>&1 | sed -n "1,40p"'
```

Expected secure pattern:

- `OPENCLAW_GATEWAY_BIND=loopback`
- Tailscale sidecar uses host networking and serves OpenClaw from `127.0.0.1:18789`
- `tailscale serve` forwards to `127.0.0.1:18789`

## Recovery commands

```bash
bin/agent-stack-ssh -- sudo systemctl restart agent-stack
bin/agent-stack-ssh -- sudo docker restart <tailscale_container>
bin/agent-stack-ssh -- systemctl status --no-pager agent-stack-tailscale-watchdog.timer
```

## Pairing commands

```bash
bin/agent-stack-ssh -- sudo docker compose -f /opt/agent-stack/docker-compose.yml exec -T openclaw openclaw devices list
bin/agent-stack-ssh -- sudo docker compose -f /opt/agent-stack/docker-compose.yml exec -T openclaw openclaw devices approve <requestId>
```
