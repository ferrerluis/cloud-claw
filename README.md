# AgentStack

> Terraform repo for a secure, self-hosted agent + automation stack.
> Deploy OpenClaw, Hermes, n8n, and local Postgres to **AWS (EC2)**, **DigitalOcean (Droplet)**, or **Hetzner Cloud** by changing a single variable.
> After `terraform apply`, the server boots with the selected services installed, configured, and running — no manual steps.

---

## What gets deployed

| Component | AWS | DigitalOcean | Hetzner Cloud |
|-----------|-----|--------------|---------------|
| Compute | EC2 t3.small (1 vCPU / 2 GB) | Droplet s-2vcpu-2gb (2 vCPU / 2 GB / 60 GB root disk) | cpx21 (default, sized for full stack) |
| Persistent storage | 50 GB gp3 EBS volume | 20 GB Block Storage volume | 50 GB Cloud volume |
| Networking | VPC, subnet, IGW, route table | VPC | Public server network |
| Firewall | Security Group: SSH + Tailscale UDP, optional 80/443 | Firewall: SSH + Tailscale UDP, optional 80/443 | Firewall: SSH + Tailscale UDP, optional 80/443 |
| Private access | Tailscale (optional but strongly recommended) | same | same |

All sizes are defaults and are adjustable through variables.

## How it bootstraps

Bootstrap is intentionally split into two provider-neutral phases:

1. `cloud-init` runs a small first-boot loader on AWS, DigitalOcean, and Hetzner. It creates the `admin` user, installs the SSH key, waits for and mounts the persistent data volume at `/opt/agent-stack/data`, and writes `/opt/agent-stack/.loader-ready.json`.
2. Terraform waits for `cloud-init status --wait`, connects over SSH as `admin`, uploads the rendered runtime bundle into a private `/opt/agent-stack/.staging-*` directory, and runs the shared installer with `sudo`.
3. The installer writes `/opt/agent-stack/docker-compose.yml` and `/opt/agent-stack/.env`, installs Docker when needed, validates the Compose config, and creates the `agent-stack` systemd service. `openclaw.service` remains as a compatibility wrapper.
4. If enabled, starts a Tailscale sidecar container that authenticates and runs `tailscale serve` for OpenClaw over HTTPS on your tailnet.
5. Seeds a stable gateway token and allowed browser origins (`gateway.controlUi.allowedOrigins`) so first login works without manual token copy/paste.
6. Applies `openclaw_config_mode`:
   - `auto` (default): preserve an existing `openclaw.json`, manage fresh installs
   - `manage`: always apply starter channel/model bootstrap changes
   - `preserve`: skip optional channel/model bootstrap changes
7. After OpenClaw first-run initialization, seeds starter workspace files (create-if-missing) in `/home/node/.openclaw/workspace`: `SOUL.md`, `AGENTS.md`, `TOOLS.md`, `USER.md`
8. Installs/enables only the selected `agent_channel` plugin (`telegram` or `whatsapp`)
9. If `agent_channel = "telegram"` and `telegram_bot_token` is set, preconfigures `channels.telegram.botToken`, enables Telegram channel config, and sets `channels.telegram.streaming = "off"` for clean final-message delivery
   - If `telegram_allow_from` is non-empty, writes `channels.telegram.allowFrom` with those pre-approved user IDs
10. Registers `ANTHROPIC_AUTH_KEY` only when the `anthropic` provider is selected
11. Configures only user-selected model routing:
    - required `default_model`
    - ordered `fallback_models`
    - restricted to explicitly selected `model_providers_enabled`
12. Writes `/opt/agent-stack/.last-apply.json` with the runtime artifact checksum and selected services after a successful installer run.

OpenClaw, Hermes, n8n, and Postgres run as Docker containers. UI ports bind to `127.0.0.1` by default. If `public_domain_enabled = true`, Caddy opens 80/443, terminates HTTPS, and protects UI routes with basic auth. n8n webhook paths can remain public when `n8n_public_webhooks_enabled = true`.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Terraform ≥ 1.5 | [Install](https://developer.hashicorp.com/terraform/install) |
| SSH key pair | Optional; if omitted, Terraform auto-creates a repo-local keypair in `./.ssh` |
| Cloud credentials | AWS access key + secret, DigitalOcean API token, **or** Hetzner Cloud API token |
| LLM credentials | At least one model provider credential: Anthropic/OpenAI/Groq/Gemini API key, or imported Codex auth for subscription-backed OpenAI |
| Tailscale account (recommended) | [Sign up free](https://tailscale.com/) — generate an auth key |

---

## Quick start

```bash
# 1. Clone
git clone <this-repo> agent-stack
cd agent-stack

# 2. Create your variables file (never commit this)
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # fill in credentials, keys, etc.
# Required before apply: model_providers_enabled, default_model, fallback_models

# 3. Initialise
terraform init

# 4. Preview
terraform plan

# 5. Deploy
terraform apply

# Terraform auto-resolves SSH key at plan/apply:
# - if ssh_public_key is explicitly set, it uses that
# - else it uses/creates ./.ssh/id_ed25519_agent_stack(.pub)
# Terraform also writes ./.ssh/config (disable with generate_repo_ssh_config = false)

# 6. Watch bootstrap/provisioning (takes ~2-3 min)
# Terraform waits for cloud-init and then runs the runtime installer over SSH.
# The SSH command and log tail command are shown in the outputs.
```

After `apply` completes, Terraform prints:

```
instance_public_ip     = "1.2.3.4"
ssh_command            = "ssh admin@1.2.3.4"
repo_ssh_command       = "./bin/agent-stack-ssh"
repo_ssh_config_path   = "./.ssh/config"
resolved_ssh_public_key_source = "existing_public_key"
tailscale_note         = "Tailscale is enabled. Sidecar device 'openclaw' will appear in your admin console..."
dashboard_url          = "https://openclaw  (via Tailscale Serve)"
dashboard_url_with_token_import = "https://openclaw/#token=<gateway-token>"
openclaw_url           = "https://openclaw  (via Tailscale Serve)"
hermes_url             = "http://localhost:9119  (after SSH tunnel)"
n8n_url                = "http://localhost:5678  (after SSH tunnel)"
n8n_webhook_url        = "http://localhost:5678/webhook  (after SSH tunnel)"
pair_latest_command    = "ssh admin@1.2.3.4 'docker compose -f /opt/agent-stack/docker-compose.yml exec -T openclaw openclaw devices approve --latest --token <gateway-token> --url ws://127.0.0.1:18789'"
repo_pair_latest_command = "./bin/agent-stack-ssh -- docker compose -f /opt/agent-stack/docker-compose.yml exec -T openclaw openclaw devices approve --latest --token <gateway-token> --url ws://127.0.0.1:18789"
whatsapp_login_command = "ssh -t admin@1.2.3.4 'docker compose -f /opt/agent-stack/docker-compose.yml exec openclaw openclaw channels login --channel whatsapp --verbose'"
bootstrap_log_command  = "ssh admin@1.2.3.4 'tail -f /var/log/openclaw-bootstrap.log'"
repo_bootstrap_log_command = "./bin/agent-stack-ssh -- tail -f /var/log/openclaw-bootstrap.log"
```

Run `bootstrap_log_command` to watch the install progress in real time.

## OpenAI Auth Modes

For direct OpenAI Platform billing, use API-key mode with canonical `openai/*` model refs:

```hcl
model_providers_enabled = ["openai"]
openai_auth_mode        = "api_key"
openai_api_key          = "sk-..."
default_model           = "openai/gpt-5.4"
fallback_models         = ["openai/gpt-5.4-mini"]
```

For ChatGPT subscription-backed Codex auth, keep the provider namespace as `openai`, switch runtime auth mode to `codex`, and import `~/.codex/auth.json`:

```hcl
model_providers_enabled           = ["openai"]
openai_auth_mode                  = "codex"
default_model                     = "openai/gpt-5.5"
fallback_models                   = ["openai/gpt-5.4-mini"]
openai_codex_auth_json_base64     = "..."
```

Legacy `openai-codex/*` refs are still accepted for older configs, but new deployments should prefer `openai/*` plus `openai_auth_mode = "codex"`.

## Repo-local SSH workflow

These helpers keep SSH behavior consistent per clone and avoid editing `~/.ssh/config`.
`terraform apply` also writes `./.ssh/config` with the current instance IP/user/key path.

```bash
# Connect (host/IP comes from terraform outputs)
bin/agent-stack-ssh

# Run remote commands
bin/agent-stack-ssh -- tail -f /var/log/openclaw-bootstrap.log

# Kill stale local ssh client processes targeting the current instance
bin/agent-stack-ssh-clean
```

---

## Accessing OpenClaw

### With Tailscale (recommended)

1. Connect your laptop/desktop to the same Tailscale network (install the Tailscale client).
2. Once the server finishes bootstrapping (~2-3 min), open `dashboard_url_with_token_import` from Terraform output for first-time login.
3. If prompted for pairing approval, run `pair_latest_command` once.
4. Afterwards, you can use **https://openclaw** directly.
5. Model routing is configured from your required `default_model` + `fallback_models` selection, limited to providers listed in `model_providers_enabled`.

### Without Tailscale (SSH tunnel)

```bash
ssh -L 18789:127.0.0.1:18789 admin@<instance_public_ip>
# Then open http://localhost:18789 in your browser
```

---

## AWS setup

1. Create an AWS account and an IAM user with `AmazonEC2FullAccess` (or a least-privilege policy).
2. Generate an access key for that IAM user.
3. In `terraform.tfvars`, set `cloud_provider = "aws"` and fill in `aws_access_key`, `aws_secret_key`, `aws_region`.
4. Optionally set `aws_instance_type` and `aws_disk_size_gb`.

```hcl
cloud_provider    = "aws"
aws_region        = "us-east-1"
aws_access_key    = "AKIA..."
aws_secret_key    = "..."
aws_instance_type = "t3.small"   # upgrade to t3.medium (4 GB) or t3.large (8 GB)
aws_disk_size_gb  = 50
```

**Reusing an existing EBS volume** (e.g. after recreating the instance):

```hcl
aws_existing_volume_id = "vol-0abc123def456789"
```

The loader/installer will detect the volume by its NVMe serial number, skip formatting, and mount it at `/opt/agent-stack/data`.

---

## DigitalOcean setup

1. Create a DigitalOcean account and generate a Personal Access Token with read+write scope.
2. In `terraform.tfvars`, set `cloud_provider = "digitalocean"` and fill in `do_token`.

```hcl
cloud_provider  = "digitalocean"
do_token        = "dop_v1_..."
do_region       = "nyc3"
do_droplet_size = "s-2vcpu-2gb"  # upgrade: s-2vcpu-4gb, s-4vcpu-8gb
do_disk_size_gb = 20             # extra volume; root disk is already 60 GB
```

**Reusing an existing DO volume**:

```hcl
do_existing_volume_id   = "12345678-..."
do_existing_volume_name = "openclaw-data"
```

SSH user defaults to `admin` (customizable with `admin_username`).

---

## Hetzner Cloud setup

1. Create a Hetzner Cloud project and API token.
2. In `terraform.tfvars`, set `cloud_provider = "hetzner"` and fill in `hcloud_token`.
3. Optionally set `hcloud_location`, `hcloud_server_type`, and `hcloud_disk_size_gb`.

```hcl
cloud_provider       = "hetzner"
hcloud_token         = "..."
hcloud_location      = "ash"
hcloud_server_type   = "cpx21"
hcloud_disk_size_gb  = 50
```

**Reusing an existing Hetzner volume**:

```hcl
hcloud_existing_volume_id = "12345678"
```

The loader/installer detects the volume through `/dev/disk/by-id/scsi-0HC_Volume_<id>` and mounts it at `/opt/agent-stack/data`.

---

## Agent + automation stack

By default, AgentStack runs the complete stack:

```hcl
enabled_services = ["openclaw", "hermes", "n8n"]
```

You can run a narrower stack, for example:

```hcl
enabled_services = ["openclaw"]
```

n8n uses local Postgres by default:

```hcl
n8n_database_mode = "local_postgres"
```

Postgres data is stored on the persistent volume under `/opt/agent-stack/data/postgres`. OpenClaw, Hermes, n8n, Postgres, and Caddy are peer directories under `/opt/agent-stack/data`. To use a provider-managed or external database, set `n8n_database_mode = "external_postgres"` and provide the `external_postgres_*` connection values.

---

## Legacy layout and provider migration

New deployments use `/opt/agent-stack`. Existing `/opt/openclaw` volumes are migrated by `/usr/local/bin/agent-stack-migrate-layout` on bootstrap:

```text
/opt/agent-stack/data/openclaw
/opt/agent-stack/data/hermes
/opt/agent-stack/data/n8n
/opt/agent-stack/data/postgres
/opt/agent-stack/data/caddy
```

Do not change `cloud_provider` in-place in the same Terraform state to move providers. Create a fresh target deployment, then copy data:

```bash
skills/agent-stack-setup/scripts/migrate_provider_data.sh --precopy --source admin@old-ip --target admin@new-ip
skills/agent-stack-setup/scripts/migrate_provider_data.sh --final --source admin@old-ip --target admin@new-ip
```

`--precopy` leaves the source running but stops the target during import. `--final` stops both stacks before copying, starts only the target stack, and never destroys the old infrastructure.

---

## Optional public domains

The default access model keeps UI ports private. To expose UIs through HTTPS behind a login gate:

```hcl
public_domain_enabled = true
base_domain           = "example.com"
acme_email            = "you@example.com"
ui_auth_username      = "admin"
ui_auth_password      = "" # blank = Terraform auto-generates
```

With `base_domain`, the service hosts derive as `openclaw.example.com`, `hermes.example.com`, and `n8n.example.com`. You can override them with `openclaw_domain`, `hermes_domain`, and `n8n_domain`.

When public domains are enabled, firewalls open ports 80 and 443. UI routes require basic auth. n8n webhook paths remain public if `n8n_public_webhooks_enabled = true`.

---

## Variables reference

| Variable | Default | Description |
|----------|---------|-------------|
| `cloud_provider` | `"aws"` | `"aws"`, `"digitalocean"`, or `"hetzner"` |
| `project_name` | `"agent-stack"` | Prefix for all resource names |
| `admin_username` | `"admin"` | Standard SSH/admin username created on the VM |
| `aws_region` | `"us-east-1"` | AWS region |
| `aws_access_key` | `""` | AWS access key (or use env vars) |
| `aws_secret_key` | `""` | AWS secret key (or use env vars) |
| `aws_instance_type` | `"t3.small"` | EC2 instance size |
| `aws_ami_id` | `""` | Override AMI (blank = Ubuntu 22.04 LTS) |
| `aws_disk_size_gb` | `50` | EBS data volume size (GB) |
| `aws_existing_volume_id` | `""` | Reuse existing EBS volume |
| `do_token` | `""` | DigitalOcean API token |
| `do_region` | `"nyc3"` | DO region slug |
| `do_droplet_size` | `"s-2vcpu-2gb"` | Droplet size slug |
| `do_disk_size_gb` | `20` | Extra block storage size (GB) |
| `do_existing_volume_id` | `""` | Reuse existing DO volume (needs `do_existing_volume_name` too) |
| `do_existing_volume_name` | `""` | Name of existing DO volume |
| `hcloud_token` | `""` | Hetzner Cloud API token |
| `hcloud_location` | `"ash"` | Hetzner Cloud location |
| `hcloud_server_type` | `"cpx21"` | Hetzner server type |
| `hcloud_image` | `"ubuntu-22.04"` | Hetzner image slug |
| `hcloud_disk_size_gb` | `50` | Hetzner Cloud volume size |
| `hcloud_existing_volume_id` | `""` | Reuse existing Hetzner Cloud volume |
| `ssh_public_key` | `""` | Optional explicit SSH public key; when empty, Terraform uses/creates repo-local key |
| `allowed_ssh_cidr` | `"0.0.0.0/0"` | CIDR allowed on SSH port 22 |
| `generate_repo_ssh_config` | `true` | Auto-write `./.ssh/config` during `terraform apply` |
| `repo_ssh_host_alias` | `"agent-stack"` | Host alias written to `./.ssh/config` |
| `repo_ssh_identity_file` | `"./.ssh/id_ed25519_agent_stack"` | IdentityFile written to `./.ssh/config` |
| `repo_ssh_private_key_path` | `".ssh/id_ed25519_agent_stack"` | Repo-relative key path for auto key resolution/generation |
| `anthropic_api_key` | `""` | Anthropic API key (pay-per-token models) |
| `anthropic_auth_key` | `""` | Claude Code setup-token for native Anthropic provider auth (run `claude setup-token` to generate) |
| `openai_api_key` | `""` | OpenAI API key for `openai_auth_mode = "api_key"` |
| `openai_auth_mode` | `"api_key"` | Auth/runtime mode for `openai/*` models: `api_key` or `codex` |
| `openai_codex_auth_json_base64` | `""` | Base64 of `~/.codex/auth.json` for `openai_auth_mode = "codex"` |
| `groq_api_key` | `""` | Groq API key |
| `gemini_api_key` | `""` | Google Gemini API key |
| `telegram_bot_token` | `""` | Optional Telegram BotFather token to preconfigure `channels.telegram.botToken` |
| `telegram_allow_from` | `[]` | Optional list of pre-approved Telegram user IDs for `channels.telegram.allowFrom` |
| `openclaw_config_mode` | `"auto"` | Bootstrap config behavior: auto (preserve existing/manage fresh), manage, or preserve |
| `agent_channel` | `"telegram"` | Channel plugin bootstrap target (`telegram` or `whatsapp`) |
| `model_providers_enabled` | **required** | Explicit provider allowlist for model bootstrap (`anthropic`, `openai`, `google`, `groq`) |
| `default_model` | **required** | Default model reference set at bootstrap (for example `anthropic/claude-haiku-4-5`) |
| `fallback_models` | **required** | Ordered fallback model references (can be `[]`) |
| `openclaw_version` | `"latest"` | Docker image tag |
| `openclaw_node_options` | `""` | Optional Node.js flags for OpenClaw container runtime (set memory cap on small servers) |
| `openclaw_swap_size_mb` | `0` | Swap file size in MB (set > 0 for small RAM nodes) |
| `openclaw_health_start_period_seconds` | `120` | Docker healthcheck start_period for OpenClaw |
| `openclaw_health_retries` | `8` | Docker healthcheck retries before marking unhealthy |
| `seed_starter_workspace_files` | `true` | Seed starter workspace files when missing (`SOUL.md`, `AGENTS.md`, `TOOLS.md`, `USER.md`) |
| `starter_soul_profile` | `"balanced"` | Starter SOUL profile (`balanced`, `builder`, `researcher`) |
| `gateway_token` | `""` | Optional fixed gateway token (blank = Terraform auto-generates) |
| `enabled_services` | `["openclaw", "hermes", "n8n"]` | Services to run |
| `hermes_image` | `"nousresearch/hermes-agent:latest"` | Hermes Docker image |
| `hermes_dashboard_enabled` | `true` | Enable Hermes dashboard |
| `hermes_api_server_enabled` | `true` | Enable Hermes API server |
| `hermes_api_server_key` | `""` | Optional fixed Hermes API key |
| `n8n_image` | `"docker.n8n.io/n8nio/n8n:stable"` | n8n Docker image |
| `n8n_database_mode` | `"local_postgres"` | `local_postgres` or `external_postgres` |
| `n8n_encryption_key` | `""` | Optional fixed n8n encryption key |
| `n8n_public_webhooks_enabled` | `true` | Leave webhook paths unauthenticated when public domains are enabled |
| `n8n_generic_timezone` | `"America/New_York"` | n8n timezone |
| `postgres_image` | `"postgres:17-alpine"` | Local Postgres image |
| `postgres_database` | `"n8n"` | Local Postgres database |
| `postgres_user` | `"n8n"` | Local Postgres user |
| `postgres_password` | `""` | Optional fixed local Postgres password |
| `external_postgres_*` | varies | External Postgres connection values for n8n |
| `public_domain_enabled` | `false` | Enable Caddy HTTPS reverse proxy |
| `base_domain` | `""` | Base domain used to derive service domains |
| `openclaw_domain` / `hermes_domain` / `n8n_domain` | `""` | Explicit service domains |
| `acme_email` | `""` | ACME email for Caddy |
| `ui_auth_mode` | `"basic"` | Public-domain UI auth mode |
| `ui_auth_username` | `"admin"` | Public-domain login username |
| `ui_auth_password` | `""` | Optional fixed public-domain password |
| `tailscale_enabled` | `true` | Install and configure Tailscale |
| `tailscale_auth_key` | `""` | Tailscale auth key |

---

## Outputs

| Output | Description |
|--------|-------------|
| `instance_public_ip` | Public IP of the server |
| `ssh_command` | Full SSH command |
| `repo_ssh_command` | Repo-local SSH wrapper command (`./bin/agent-stack-ssh`) |
| `repo_ssh_config_path` | Path to generated repo-local SSH config file |
| `resolved_ssh_public_key_source` | Effective SSH key source (`tfvars_or_env`, `existing_public_key`, `derived_from_private_key`, `generated_new_keypair`) |
| `tailscale_note` | Tailscale access instructions |
| `dashboard_url` | URL to reach the OpenClaw UI |
| `dashboard_url_with_token_import` | First-time URL that auto-imports token into Control UI |
| `openclaw_url` | OpenClaw UI URL or access hint |
| `hermes_url` | Hermes dashboard URL or access hint |
| `n8n_url` | n8n UI URL or access hint |
| `n8n_webhook_url` | n8n webhook base URL or access hint |
| `ui_auth_username` | Public-domain login username |
| `ui_auth_password` | Public-domain login password (sensitive) |
| `gateway_token` | Gateway token value |
| `pair_latest_command` | One-shot command to approve the latest pending device pairing |
| `repo_pair_latest_command` | Same pairing approval using repo-local SSH wrapper |
| `whatsapp_login_command` | Interactive QR login command for WhatsApp |
| `bootstrap_log_command` | Tail the bootstrap log remotely |
| `repo_bootstrap_log_command` | Tail bootstrap logs using repo-local SSH wrapper |
| `provider_used` | Which provider was deployed |

---

## Security notes

- **No public UI ports by default** — service UIs bind to `127.0.0.1` unless `public_domain_enabled = true`.
- **Tailscale** is the recommended access path; when enabled, a Docker sidecar publishes HTTPS access with `tailscale serve`.
- The Tailscale sidecar requires `/dev/net/tun` and `NET_ADMIN` / `NET_RAW` capabilities.
- Only SSH (port 22) and Tailscale UDP (41641) are opened in firewall rules by default. Ports 80/443 open only when public domains are enabled.
- `gateway_token` and `dashboard_url_with_token_import` outputs contain credentials. Treat Terraform output/state as sensitive.
- **API keys** are rendered by Terraform into the runtime bundle and uploaded over SSH into a private `/opt/agent-stack/.staging-*` directory before being installed as `/opt/agent-stack/.env`. They are still present in Terraform state and local plan/apply material, so treat state files and plans as sensitive.
- **SSH CIDR**: set `allowed_ssh_cidr` to your own IP (`curl ifconfig.me`) — don't leave it `0.0.0.0/0` in production.
- **EBS encryption** is enabled on both the root and data volumes.
- **IMDSv2** is enforced on EC2 (HTTP tokens required, 1-hop limit).

---

## Repository structure

```
agent-stack/
├── .gitignore                          # Excludes *.tfvars, .terraform/, state files, and repo-local SSH keys
├── bin/
│   ├── agent-stack-ssh                 # Repo-local SSH wrapper (reads terraform outputs)
│   ├── agent-stack-ssh-clean           # Kills stale local SSH client processes
│   ├── agent-stack-ssh-create          # Generates repo-local SSH keypair (default: ./.ssh/id_ed25519_agent_stack)
│   └── cloud-claw-*                    # Compatibility wrappers for old local commands
├── README.md                           # This file
├── terraform.tfvars.example            # Template — copy to terraform.tfvars
├── versions.tf                         # Provider version constraints
├── variables.tf                        # All input variables (root)
├── main.tf                             # Provider configs + conditional module calls
├── outputs.tf                          # Aggregated outputs
└── modules/
    ├── aws/                            # AWS-specific resources
    │   ├── main.tf                     # VPC, EC2, EBS, security group
    │   ├── variables.tf
    │   └── outputs.tf
    ├── digitalocean/                   # DO-specific resources
    │   ├── main.tf                     # Droplet, volume, VPC, firewall
    │   ├── variables.tf
    │   └── outputs.tf
    ├── hetzner/                        # Hetzner-specific resources
    │   ├── main.tf                     # Server, volume, firewall
    │   ├── variables.tf
    │   └── outputs.tf
    └── common/
        └── templates/
            ├── cloud_init.yaml.tpl     # Shared first-boot loader (admin user + volume mount)
            ├── runtime/                # Shared SSH-provisioned runtime bundle
            └── starter/                # Starter workspace file templates
```

---

## Resizing the instance

Change `aws_instance_type`, `do_droplet_size`, or `hcloud_server_type` and re-run `terraform apply`.

- **AWS**: Terraform stops the instance, resizes it, and restarts it. The EBS data volume is unaffected.
- **DigitalOcean**: Terraform will destroy and recreate the Droplet. The Block Storage volume persists (pass the existing volume ID/name to avoid losing data).
- **Hetzner**: Terraform may recreate the server depending on the server-type change. The Cloud volume persists (pass the existing volume ID to avoid losing data).

---

## Backup and snapshots

**AWS (manual)**:
```bash
aws ec2 create-snapshot \
  --volume-id $(terraform output -raw ebs_volume_id) \
  --description "openclaw-backup-$(date +%Y%m%d)"
```

For automated EBS snapshots, enable [AWS Data Lifecycle Manager](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/snapshot-lifecycle.html) in the console.

**DigitalOcean (manual)**:
```bash
doctl compute volume snapshot <volume-id> --snapshot-name "openclaw-$(date +%Y%m%d)"
```

You can also enable [automated Droplet backups](https://docs.digitalocean.com/products/droplets/how-to/enable-backups/) from the DigitalOcean console.

**Hetzner Cloud (manual)**:
```bash
hcloud volume create-snapshot <volume-id> --description "agent-stack-$(date +%Y%m%d)"
```

---

## Google Drive sync (optional)

The installed `docker-compose.yml` includes a commented-out `rclone` service. To activate it:

1. On the server, run `rclone config` and follow the [Google Drive setup guide](https://rclone.org/drive/).
2. This creates `~root/.config/rclone/rclone.conf`.
3. Uncomment the `rclone` service block in `/opt/agent-stack/docker-compose.yml`.
4. Run `systemctl restart agent-stack` to apply the change.

The sidecar will sync `/opt/agent-stack/data/openclaw/workspace` → `gdrive:openclaw-workspace` periodically.

---

## Destroying

```bash
terraform destroy
```

> **Note**: New EBS, DigitalOcean, and Hetzner volumes created by this repo are intentionally *not* set to `prevent_destroy`, so `terraform destroy` will delete them. If you want to keep your data, take a snapshot before destroying, or set `aws_existing_volume_id`, `do_existing_volume_id`, or `hcloud_existing_volume_id` to detach the volume from Terraform management first.
