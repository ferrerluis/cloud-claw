# Workspace SSH / Codex Connection Findings

Date: 2026-07-07

## Summary

The current deployment is reachable over SSH at the protocol level, and the `workspace_username`, `workspace_password`, and `workspace_ssh_host_port` values in `terraform.tfvars` are valid for password SSH.

The root cause was a deployment/runtime discrepancy that could recur after `terraform apply` or a workspace container recreation:

1. The workspace SSH server host keys are generated inside the ephemeral container filesystem, so recreating the workspace container changes the SSH host key and causes Codex/SSH clients to reject the host with `REMOTE HOST IDENTIFICATION HAS CHANGED`.

That host-key regeneration was the immediate Codex Desktop failure observed on this machine.

There was also a separate output/documentation mismatch: Terraform advertised the workspace host as the short name `agent-stack`, but the more reliable phone target is the full Tailscale DNS name `agent-stack.taila9790b.ts.net`.

Implemented live repair:

- Persisted workspace SSH host keys under `/opt/agent-stack/data/workspace/ssh-host-keys`.
- Updated the workspace container to mount those keys at `/var/lib/agent-stack-workspace/ssh-host-keys`.
- Updated the workspace entrypoint to configure sshd with explicit persistent `HostKey` files.
- Pre-seeded the persistent directory from the current running container before rollout, avoiding another host-key rotation.
- Added `admin_ssh_host_override` and set this deployment to use `agent-stack.taila9790b.ts.net` for Terraform runtime provisioning, because public-IP admin SSH to `5.161.207.253:22` timed out while tailnet admin SSH worked.
- Applied Terraform without replacing the VPS.
- Force-recreated the workspace container and verified the endpoint ED25519 fingerprint remained unchanged.
- Confirmed Codex can connect again from both Codex Mobile and Codex Desktop after trusting the current stable workspace host key.

Remaining follow-up is local repo hygiene, not live connection repair:

- Commit the Terraform/runtime/test changes as one scoped SSH-host-key durability fix.
- Keep or separately discard the unrelated pre-existing staged `host-tailscale-bootstrap.sh.tpl` change.
- Optionally add a future AgentStack Doctor check that compares the live workspace SSH fingerprint against the local `known_hosts` entry.

## 2026-07-07 Follow-Up: Laptop Tailnet TCP Failure

After the workspace SSH host-key repair, the laptop later could not reach either admin SSH or workspace SSH over the tailnet even though the phone could connect and `tailscale ping` from the laptop returned `pong`.

This turned out to be a local laptop routing conflict, not a workspace SSH server failure:

- macOS had both Tailscale and NordVPN NordLynx connected.
- Tailscale CLI control-plane operations worked, including `tailscale ping`.
- Ordinary OS-level TCP to tailnet addresses timed out, including:
  - `100.67.58.62:22`
  - `100.67.58.62:2222`
  - `100.67.58.62:443`
  - `100.100.100.100:53`
- The macOS route table showed NordLynx on `utun11` and Tailscale on `utun12`, with competing VPN routes.
- After disconnecting NordVPN NordLynx locally, MagicDNS and OS-level TCP worked again.

Post-disconnect laptop verification:

```text
dig +short agent-stack.taila9790b.ts.net @100.100.100.100
# 100.67.58.62

ssh admin@agent-stack.taila9790b.ts.net
# ok

ssh -p 2222 user@agent-stack.taila9790b.ts.net true
# ok
```

Workspace verification through the restored admin path:

```text
agent-stack-openclaw-1: healthy
agent-stack-workspace-1: healthy
/home/user/.codex/config.toml: user:user 0600
workspace user can read Codex config: yes
workspace ED25519 fingerprint: SHA256:xK34etTcooEcQzTLJdoMioGQmn+HJ+KWy5M65c3MJbw
```

### VPS Host VPN Recovery Caveat

During the same incident, host admin SSH was also unreachable over both public SSH and Tailscale SSH. To recover access, the VPS was booted into Hetzner rescue mode and the installed OS was edited offline:

- Removed the destructive `ExecStop=/bin/systemctl stop agent-stack.service` from `/etc/systemd/system/openclaw.service`.
- Removed `100.64.0.0/10` from `/etc/agent-stack-vpn/bypass-cidrs.json`.
- Disabled/gated `agent-stack-vpn.service` so the normal OS could boot with SSH reachable.
- Removed the hard `Requires=agent-stack-vpn.service` and `After=agent-stack-vpn.service` dependency from the live `/etc/systemd/system/agent-stack.service`.

Current live state after rescue recovery:

```text
ssh.service: active
tailscaled.service: active
agent-stack.service: active
openclaw.service: active
agent-stack-vpn.service: inactive
OpenClaw health: {"ok":true,"status":"live"}
workspace SSH: reachable from laptop and phone
```

The recovered state has been codified with Terraform:

```text
vpn_enabled = false
terraform plan -refresh=false: No changes
terraform_data.runtime_apply: not tainted
```

Final verification from the laptop:

```text
admin SSH: ssh admin@agent-stack.taila9790b.ts.net -> ok
workspace SSH: ssh -p 2222 user@agent-stack.taila9790b.ts.net -> ok
workspace Codex config: /home/user/.codex/config.toml readable by user
agent-stack-openclaw-1: healthy
agent-stack-workspace-1: healthy
agent-stack-vpn.service: inactive
```

Do not re-enable the host VPN until the VPN routing model is fixed and validated. In particular, do not route `100.64.0.0/10` through the original public gateway; that can break Tailscale data-plane traffic.

## Current Terraform Inputs

From `terraform.tfvars`:

```hcl
workspace_username      = "user"
workspace_ssh_host_port = 2222
```

`workspace_password` is set in `terraform.tfvars` and should be treated as sensitive. Do not paste it into logs, docs, or issue comments.

## Current Runtime Evidence

AgentStack service and workspace container are running:

```bash
bin/agent-stack-ssh -- sudo systemctl is-active agent-stack
bin/agent-stack-ssh -- "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
```

Observed state:

```text
agent-stack.service: active
agent-stack-workspace-1: healthy
workspace port mapping: 0.0.0.0:2222->22/tcp
```

Post-repair verification:

```text
agent-stack-workspace-1: recreated and healthy
OpenClaw health: {"ok":true,"status":"live"}
workspace ED25519 fingerprint before recreation: SHA256:xK34etTcooEcQzTLJdoMioGQmn+HJ+KWy5M65c3MJbw
workspace ED25519 fingerprint after recreation:  SHA256:xK34etTcooEcQzTLJdoMioGQmn+HJ+KWy5M65c3MJbw
password SSH probe: ok
Codex Desktop: remote workspace activity observed in logs under /home/user/workspace
```

Current Tailscale identity from the VM:

```bash
bin/agent-stack-ssh -- "tailscale status --json | jq -r '.Self.HostName, .Self.DNSName, (.Self.TailscaleIPs[]? // empty), (.CertDomains[]? // empty)'"
```

Observed:

```text
HostName: agent-stack
DNSName: agent-stack.taila9790b.ts.net.
Tailscale IPv4: 100.67.58.62
Tailscale IPv6: fd7a:115c:a1e0::d337:3a3f
CertDomain: agent-stack.taila9790b.ts.net
```

The Terraform output is now configured to say:

```bash
terraform output -raw workspace_ssh_command
# ssh -p 2222 user@agent-stack.taila9790b.ts.net
```

The working host is:

```text
agent-stack.taila9790b.ts.net
```

The admin SSH helper path has been corrected separately:

```hcl
admin_ssh_host_override = "agent-stack.taila9790b.ts.net"
workspace_ssh_host_override = "agent-stack.taila9790b.ts.net"
```

That makes `terraform_data.runtime_apply`, `ssh_command`, generated `.ssh/config`, repo helper output, and workspace SSH outputs use the tailnet hostname instead of unreachable or misleading defaults.

## Immediate Codex Desktop Failure, Now Resolved On Laptop And Mobile

Codex Desktop logs showed this error for the configured remote:

```text
REMOTE HOST IDENTIFICATION HAS CHANGED
Offending ED25519 key in /Users/ferrerluis/.ssh/known_hosts:60
Host key for [agent-stack.taila9790b.ts.net]:2222 has changed and you have requested strict checking.
Host key verification failed.
```

The new/current workspace SSH host key fingerprint is:

```text
SHA256:xK34etTcooEcQzTLJdoMioGQmn+HJ+KWy5M65c3MJbw
```

This matches the key Codex was rejecting as changed.

Laptop mitigation applied during diagnosis:

```bash
cp /Users/ferrerluis/.ssh/known_hosts .tmp/known_hosts.backup-20260706T0252Z
ssh-keygen -R '[agent-stack.taila9790b.ts.net]:2222' -f /Users/ferrerluis/.ssh/known_hosts
ssh-keyscan -H -p 2222 agent-stack.taila9790b.ts.net >> /Users/ferrerluis/.ssh/known_hosts
```

This only fixed the local laptop trust cache. It did not fix the root cause, and it did not clear stale host-key trust on Codex Mobile.

The root cause is now fixed for future workspace container recreations by persisting server host keys. Codex Mobile was recovered by changing the connection target to the current Tailscale DNS name, which created a fresh known-host trust path:

```text
user@agent-stack.taila9790b.ts.net:2222
```

## Root Cause: Ephemeral Workspace Host Keys

The workspace compose service persists only the home directory:

```yaml
volumes:
  - /opt/agent-stack/data/workspace/home:/home/${workspace_username}
```

The workspace entrypoint then generates SSH host keys inside the container:

```bash
ssh-keygen -A
exec /usr/sbin/sshd -D -e
```

Because `/etc/ssh/ssh_host_*` is not persisted, a recreated workspace container can present a different host key at the same stable Tailscale DNS name and port. SSH clients correctly interpret this as a possible MITM and refuse to connect.

That is why this can break after an apply/restart even when:

- Tailscale is online
- port `2222` is open
- `workspace_username` and `workspace_password` are correct
- raw password SSH succeeds after accepting the new host key

## Secondary Finding: Terraform Output Used a Short Host Assumption

`outputs.tf` previously built workspace SSH commands with `var.project_name`:

```hcl
value = local.workspace_enabled ? "ssh -p ${var.workspace_ssh_host_port} ${var.workspace_username}@${var.project_name}" : "disabled"
```

But the live Tailscale DNS name can differ from `project_name`, especially when the device is manually renamed in the Tailscale UI. In this deployment:

```text
project_name = agent-stack
actual MagicDNS/FQDN = agent-stack.taila9790b.ts.net
```

The repo now supports `workspace_ssh_host_override` so Terraform outputs and the final workspace SSH message do not have to assume `${project_name}`.

This is not the current Codex connection blocker because the configured Codex remotes are using the correct FQDN:

```text
user@agent-stack.taila9790b.ts.net:2222
```

The host-key churn blocker is fixed by the persisted host-key implementation described below.

## Implemented Root Fix

### 1. Persist Workspace SSH Host Keys

The repo fix is to add a persistent host-key directory for the workspace service:

```yaml
volumes:
  - /opt/agent-stack/data/workspace/home:/home/${workspace_username}
  - /opt/agent-stack/data/workspace/ssh-host-keys:/var/lib/agent-stack-workspace/ssh-host-keys
```

`workspace-entrypoint.sh.tpl` should generate host keys in that persistent directory if missing, and configure sshd to use them:

```bash
host_key_dir=/var/lib/agent-stack-workspace/ssh-host-keys
install -d -m 0700 -o root -g root "$host_key_dir"

if [ ! -f "$host_key_dir/ssh_host_ed25519_key" ]; then
  ssh-keygen -t ed25519 -N "" -f "$host_key_dir/ssh_host_ed25519_key"
fi

cat >/etc/ssh/sshd_config.d/98-agent-stack-host-keys.conf <<EOF
HostKey $host_key_dir/ssh_host_ed25519_key
EOF
```

The implementation persists ED25519, ECDSA, and RSA host keys for standard OpenSSH compatibility.

Acceptance criteria:

1. Apply/restart/recreate the workspace container.
2. Confirm the host key fingerprint is unchanged:

   ```bash
   ssh-keyscan -p 2222 agent-stack.taila9790b.ts.net | ssh-keygen -lf -
   ```

3. Codex Desktop and Codex Mobile do not require clearing host trust after future `terraform apply` runs.

Current status:

```text
Implemented and deployed.
Verified by forced workspace container recreation.
```

## Additional Live Finding: Public Admin SSH Timed Out

During the live repair, public admin SSH to the Terraform `instance_public_ip` failed:

```text
ssh admin@5.161.207.253
# timed out
```

Host admin SSH over the tailnet worked:

```text
ssh admin@agent-stack.taila9790b.ts.net
# ok
```

Because `terraform_data.runtime_apply` previously used only `local.instance_public_ip`, Terraform could not repair a host that was reachable over Tailscale but not over public SSH. The added `admin_ssh_host_override` variable fixes that gap while preserving the public IP as the default for first-time installs.

### 2. Stop Assuming `${project_name}` Is the SSH Host

Terraform output should not claim `user@agent-stack` when the actual reachable MagicDNS name is different. This is implemented with `workspace_ssh_host_override`, which feeds `workspace_ssh_command`, `workspace_codex_login_command`, and the runtime installer handoff message.

Acceptance criteria:

1. `terraform output -raw workspace_ssh_command` or the setup/doctor output points to the actual host the Codex apps should use.
2. The emitted host resolves from the laptop and phone Tailscale clients.
3. The output includes port `2222`.

Current status:

```text
Implemented in Terraform outputs and runtime handoff.
Live deployment configured with workspace_ssh_host_override = "agent-stack.taila9790b.ts.net".
```

### 3. Add a Doctor Check for This Exact Failure

Enhance `skills/agent-stack-doctor/scripts/check_remote_health.sh` or add a focused checker to report:

- live Tailscale `Self.DNSName`
- Terraform `workspace_ssh_command`
- whether the Terraform host resolves locally
- current workspace SSH host key fingerprint
- whether the local `known_hosts` entry for `[host]:port` matches the current server key

The doctor should explicitly diagnose:

```text
Codex/SSH clients may fail because the workspace SSH host key changed.
This is caused by non-persistent workspace host keys.
```

## Phone-Specific Note

Codex Mobile has its own SSH host key/trust record. Clearing the laptop `~/.ssh/known_hosts` entry does not clear the phone cache.

The root host-key persistence fix is deployed, and the phone is now connected using the current ED25519 fingerprint:

```text
SHA256:xK34etTcooEcQzTLJdoMioGQmn+HJ+KWy5M65c3MJbw
```

If another mobile client later refuses an existing FQDN before it shows a new host-key prompt, use one of these recovery paths:

1. Delete the existing Codex Mobile SSH remote/profile for `agent-stack.taila9790b.ts.net:2222`, then recreate it with:

   ```text
   host: agent-stack.taila9790b.ts.net
   port: 2222
   username: user
   auth: workspace password from terraform.tfvars
   expected ED25519 fingerprint: SHA256:xK34etTcooEcQzTLJdoMioGQmn+HJ+KWy5M65c3MJbw
   ```

2. If the app still keeps a stale known-host entry after deleting/recreating the profile, connect with the Tailscale IPv4 address instead. This creates a fresh known-host key slot on the phone:

   ```text
   host: 100.67.58.62
   port: 2222
   username: user
   auth: workspace password from terraform.tfvars
   expected ED25519 fingerprint: SHA256:xK34etTcooEcQzTLJdoMioGQmn+HJ+KWy5M65c3MJbw
   ```

The Tailscale IP path was verified from the laptop:

```text
100.67.58.62:2222 reachable
[100.67.58.62]:2222 ED25519 fingerprint: SHA256:xK34etTcooEcQzTLJdoMioGQmn+HJ+KWy5M65c3MJbw
```

## Commands Used During Diagnosis

Check live service/container state:

```bash
bin/agent-stack-ssh -- sudo systemctl is-active agent-stack
bin/agent-stack-ssh -- "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
```

Check live Tailscale DNS:

```bash
bin/agent-stack-ssh -- "tailscale status --json | jq -r '.Self.HostName, .Self.DNSName, (.Self.TailscaleIPs[]? // empty), (.CertDomains[]? // empty)'"
```

Check workspace host key:

```bash
bin/agent-stack-ssh -- "sudo docker exec agent-stack-workspace-1 sh -lc 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'"
```

Check authorized user key:

```bash
bin/agent-stack-ssh -- "sudo docker exec agent-stack-workspace-1 sh -lc 'ssh-keygen -lf /home/user/.ssh/authorized_keys'"
```

Check whether the Terraform-emitted host resolves:

```bash
ssh-keyscan -p 2222 -T 5 agent-stack
```

Check current known_hosts entry:

```bash
ssh-keygen -F '[agent-stack.taila9790b.ts.net]:2222' -f /Users/ferrerluis/.ssh/known_hosts
```
