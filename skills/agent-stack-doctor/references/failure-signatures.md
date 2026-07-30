# Failure Signatures

## Dashboard and Tailscale

- `ERR_CONNECTION_REFUSED` on the tailnet URL:
  - OpenClaw is not listening on `127.0.0.1:18789`, or the Tailscale sidecar or serve config is unhealthy.
- `origin not allowed` in the Control UI:
  - `gateway.controlUi.allowedOrigins` is missing the dashboard origin.
- `unauthorized: gateway token missing`:
  - Use `dashboard_url_with_token_import` from Terraform output.

## Pairing and channels

- `pairing required`:
  - Approve the pending device request with `repo_pair_latest_command` or `pair_latest_command`.
- Telegram setup did not happen:
  - `agent_channel = "telegram"` but `telegram_bot_token` is blank, so bootstrap skipped plugin and channel setup.
- WhatsApp login missing:
  - The plugin may be enabled, but the user still needs to run the QR login command from Terraform output.

## Bootstrap and runtime

- Bootstrap appears stuck:
  - Check `/var/log/openclaw-bootstrap.log` for hung plugin commands or missing Tailscale auth.
- Gateway takes 60-90s to report healthy:
  - Early `health: starting` can be transient after restart or upgrade.
- Host-level `curl http://127.0.0.1:18789` resets:
  - Verify both in-container health and sidecar-to-app reachability before declaring the service down.

## Data and configuration

- Reused volume behaves like a preserve install:
  - `openclaw_config_mode = "auto"` becomes preserve when bootstrap sees an existing `openclaw.json`.
- Data recovery issues:
  - Restore contents into `/opt/agent-stack/data`, preserving `openclaw`, `hermes`, `n8n`, `postgres`, and `caddy` as peer directories.
- Partial layout migration:
  - `/opt/agent-stack` and a real `/opt/openclaw` directory both exist. Rerun `/usr/local/bin/agent-stack-migrate-layout` after stopping the stack.
- Workspace file exists locally but not in Drive:
  - Treat this as a missing or failed FUSE mount. Run `sudo agent-stack-workspace-drive doctor`; never start a second sync job over the same tree.
- `workspace Drive deployment blocked by local residue`:
  - The fail-closed preflight found files beneath the intended mountpoint. Run `sudo agent-stack-workspace-drive recovery-dry-run`; upload and quarantine require separate explicit confirmation flags.
- Workspace container is restarting or unhealthy with Drive FUSE enabled:
  - Check `/dev/fuse`, the custom OAuth client fields, rclone logs, and `sudo agent-stack-workspace-drive status`. SSH is intentionally withheld whenever the mount cannot be verified.
- `findmnt` reports `fuse.rclone` but reads fail with `Transport endpoint is not connected`:
  - The kernel retained a stale FUSE record after rclone exited. Managed Drive mode exits and lets Docker restart the workspace. For an already-deployed legacy `workspace_fuse_enabled` container, install the tracked `workspace_drive_mount_watchdog.sh` as `~/.local/bin/workspace-drive-mount`, run `workspace-drive-mount start`, and verify `workspace-drive-mount doctor`. The watchdog uses `fusermount3 -uz` before remounting; never start a second unsupervised rclone process.

## Model and provider mismatch

- Anthropic models are selected but never become usable:
  - Current bootstrap checks `ANTHROPIC_AUTH_KEY`, not just `ANTHROPIC_API_KEY`, when configuring Anthropic models.
- Model exists in config but is skipped at runtime:
  - The provider may not be listed in `model_providers_enabled`, the credential may be missing, or the model may be absent from the runtime catalog.
