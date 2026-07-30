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
- `terraform output -raw workspace_drive_status_command`
- `terraform output -raw workspace_drive_recovery_command`

## Bootstrap checks

- Watch the bootstrap log: `bin/agent-stack-ssh -- tail -f /var/log/openclaw-bootstrap.log`
- Check the service: `bin/agent-stack-ssh -- sudo systemctl status --no-pager agent-stack`
- Check containers: `bin/agent-stack-ssh -- sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'`
- Check selected local services on the VM:
  - OpenClaw: `bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:18789/healthz`
  - Hermes: `bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:9119`
  - n8n: `bin/agent-stack-ssh -- curl -sv --max-time 5 http://127.0.0.1:5678/healthz`
  - Workspace Drive FUSE: `bin/agent-stack-ssh -- sudo agent-stack-workspace-drive doctor`

## Workspace Drive checks

- A healthy FUSE deployment reports the workspace container as healthy and `Drive mount: healthy` from `sudo agent-stack-workspace-drive status`.
- Verify that `findmnt -M /home/<workspace_username>/workspace` inside the workspace container reports `fuse.rclone`.
- Keep `workspace_fuse_enabled = false` when `workspace_drive_fuse_enabled = true`; Terraform rejects enabling both modes together.
- If apply reports local residue, run `sudo agent-stack-workspace-drive recovery-dry-run`. Nothing is uploaded, moved, or deleted until the exact confirmation flag for a recovery command is supplied.
- After `recover-copy --confirm-upload`, review the files in Drive before stopping the workspace and using `quarantine --confirm-quarantine`.

## Tailscale checks

- Read `terraform output -raw tailscale_note`
- If Tailscale is enabled, confirm the sidecar is online and serving the dashboard:
  - `bin/agent-stack-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock status --json`
  - `bin/agent-stack-ssh -- sudo docker exec <tailscale_container> tailscale --socket=/tmp/tailscaled.sock serve status`

## Workspace Codex updater rollout

Use this sequence only when `workspace` is enabled.

1. In the first approved runtime-only rollout, set `workspace_codex_auto_update_enabled = true` and keep `workspace_codex_auto_recover_interrupted_turns = false`. The fallback `workspace_codex_release` must be a stable `x.y.z` release.
2. Verify fresh workspace SSH access and the canonical live command as the workspace user: `command -v codex` should be `/home/<workspace_username>/.local/bin/codex`, and `codex --version` should succeed.
3. Confirm the non-catch-up timer is scheduled for the configured daily local time, rather than a startup run or idle-time polling. Confirm `agent-stack-diagnostics codex-update status` reports the effective version and timer state. Before a scheduled update, Codex must report its canonical managed daemon; the worker refuses an unmanaged app server or a competing legacy hourly updater instead of taking it over.
4. Run the root-admin-only disposable-thread visual E2E probe in the desktop client. Prove that a deliberately interrupted turn is recognized and that the resulting recovery turn contains the safety instruction without replaying prior commands.
5. Only after that probe succeeds, use a second targeted approved apply to set `workspace_codex_auto_recover_interrupted_turns = true`.

The probe's one new recovery turn must use this safety instruction:

> A scheduled Codex CLI update restarted the app-server and interrupted your prior turn. Do not repeat external or destructive actions. First inspect the thread and current workspace/runtime state, report what remains, and wait for the user before taking further action.

The scheduled worker retries only pre-restart technical failures at +5, +15, and +35 minutes after the configured cutover. A successful `codex update` can restart the app server and interrupt active work. Recovery can append one deduplicated new safety-constrained turn only for a proven interrupted turn; it cannot restore an in-flight turn, replay the old request, or guarantee recovery of a turn created between the snapshot and restart. If update or post-restart verification fails, the updater restores the prior CLI target once and defers further work until the next night.

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
