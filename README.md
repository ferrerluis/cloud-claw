# cloud-claw

> Terraform repo for a secure, self-hosted [OpenClaw](https://github.com/openclaw/openclaw) deployment.
> Deploy to **AWS (EC2)** or **DigitalOcean (Droplet)** by changing a single variable.
> After `terraform apply`, the server boots with OpenClaw already installed, configured, and running — no manual steps.

---

## What gets deployed

| Component | AWS | DigitalOcean |
|-----------|-----|-------------|
| Compute | EC2 t3.small (1 vCPU / 2 GB) | Droplet s-2vcpu-2gb (2 vCPU / 2 GB / 60 GB root disk) |
| Persistent storage | 50 GB gp3 EBS volume (separate from 20 GB OS disk) | 20 GB Block Storage volume (root disk already 60 GB) |
| Networking | VPC, subnet, IGW, route table | VPC |
| Firewall | Security Group: SSH + Tailscale UDP | Firewall: SSH + Tailscale UDP |
| Private access | Tailscale (optional but strongly recommended) | same |

All sizes are defaults and are adjustable through variables.

## How it bootstraps

On first boot, `cloud-init` runs a script that:

1. Installs Docker and Docker Compose
2. Locates, formats (first time), and mounts the persistent data volume
3. Writes `/opt/openclaw/docker-compose.yml` and `/opt/openclaw/.env`
4. Creates and starts a `systemd` service (`openclaw`) that runs `docker compose up`
5. If enabled, starts a Tailscale sidecar container that authenticates and runs `tailscale serve` to proxy `127.0.0.1:18789` over HTTPS on your tailnet
6. Seeds a stable gateway token and allowed browser origins (`gateway.controlUi.allowedOrigins`) so first login works without manual token copy/paste
7. Enables bundled `whatsapp` and `telegram` channel plugins
8. If `telegram_bot_token` is set, preconfigures `channels.telegram.botToken`, enables Telegram channel config, and sets `channels.telegram.streaming = "off"` for clean final-message delivery
   - If `telegram_allow_from` is non-empty, writes `channels.telegram.allowFrom` with those pre-approved user IDs
9. Sets `agents.defaults.contextPruning` to `cache-ttl` defaults to reduce oversized tool/session context on long-running chats
10. If `GROQ_API_KEY` is set, configures model routing defaults:
   - Primary: `groq/meta-llama/llama-4-maverick-17b-128e-instruct`
   - Fallbacks (when provider key is present): GPT 5.3 Codex (`openai-codex`), Gemini 3 Pro

OpenClaw runs as a Docker container with ports **bound to 127.0.0.1** only — never publicly exposed.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Terraform ≥ 1.5 | [Install](https://developer.hashicorp.com/terraform/install) |
| SSH key pair | `ssh-keygen -t ed25519` — you'll paste the `.pub` content |
| Cloud credentials | AWS access key + secret, **or** DigitalOcean API token |
| LLM API key(s) | At least one of: Anthropic, OpenAI, Groq, or Gemini |
| Tailscale account (recommended) | [Sign up free](https://tailscale.com/) — generate an auth key |

---

## Quick start

```bash
# 1. Clone
git clone <this-repo> cloud-claw
cd cloud-claw

# 2. Create your variables file (never commit this)
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # fill in credentials, keys, etc.

# 3. Initialise
terraform init

# 4. Preview
terraform plan

# 5. Deploy
terraform apply

# 6. Watch bootstrap (takes ~2-3 min)
# The SSH command and log tail command are shown in the outputs.
```

After `apply` completes, Terraform prints:

```
instance_public_ip     = "1.2.3.4"
ssh_command            = "ssh admin@1.2.3.4"
tailscale_note         = "Tailscale is enabled. Sidecar device 'openclaw' will appear in your admin console..."
dashboard_url          = "https://openclaw  (via Tailscale Serve)"
dashboard_url_with_token_import = "https://openclaw/#token=<gateway-token>"
pair_latest_command    = "ssh admin@1.2.3.4 'docker exec openclaw-openclaw-1 openclaw devices approve --latest --token <gateway-token> --url ws://127.0.0.1:18789'"
whatsapp_login_command = "ssh -t admin@1.2.3.4 'sudo docker exec -it openclaw-openclaw-1 openclaw channels login --channel whatsapp --verbose'"
bootstrap_log_command  = "ssh admin@1.2.3.4 'tail -f /var/log/openclaw-bootstrap.log'"
```

Run `bootstrap_log_command` to watch the install progress in real time.

---

## Accessing OpenClaw

### With Tailscale (recommended)

1. Connect your laptop/desktop to the same Tailscale network (install the Tailscale client).
2. Once the server finishes bootstrapping (~2-3 min), open `dashboard_url_with_token_import` from Terraform output for first-time login.
3. If prompted for pairing approval, run `pair_latest_command` once.
4. Afterwards, you can use **https://openclaw** directly.
5. Model defaults are pre-seeded when matching API keys are present. If you include Codex fallback, complete one-time `openai-codex` auth to make that fallback usable.

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

The bootstrap script will detect the volume by its NVMe serial number, skip formatting, and mount it at `/opt/openclaw/data`.

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

## Variables reference

| Variable | Default | Description |
|----------|---------|-------------|
| `cloud_provider` | `"aws"` | `"aws"` or `"digitalocean"` |
| `project_name` | `"openclaw"` | Prefix for all resource names |
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
| `ssh_public_key` | — | SSH public key content (required) |
| `allowed_ssh_cidr` | `"0.0.0.0/0"` | CIDR allowed on SSH port 22 |
| `anthropic_api_key` | `""` | Anthropic API key |
| `openai_api_key` | `""` | OpenAI API key |
| `groq_api_key` | `""` | Groq API key |
| `gemini_api_key` | `""` | Google Gemini API key |
| `telegram_bot_token` | `""` | Optional Telegram BotFather token to preconfigure `channels.telegram.botToken` |
| `telegram_allow_from` | `[]` | Optional list of pre-approved Telegram user IDs for `channels.telegram.allowFrom` |
| `openclaw_version` | `"latest"` | Docker image tag |
| `gateway_token` | `""` | Optional fixed gateway token (blank = Terraform auto-generates) |
| `tailscale_enabled` | `true` | Install and configure Tailscale |
| `tailscale_auth_key` | `""` | Tailscale auth key |

---

## Outputs

| Output | Description |
|--------|-------------|
| `instance_public_ip` | Public IP of the server |
| `ssh_command` | Full SSH command |
| `tailscale_note` | Tailscale access instructions |
| `dashboard_url` | URL to reach the OpenClaw UI |
| `dashboard_url_with_token_import` | First-time URL that auto-imports token into Control UI |
| `gateway_token` | Gateway token value |
| `pair_latest_command` | One-shot command to approve the latest pending device pairing |
| `whatsapp_login_command` | Interactive QR login command for WhatsApp |
| `bootstrap_log_command` | Tail the bootstrap log remotely |
| `provider_used` | Which provider was deployed |

---

## Security notes

- **No public ports** for the OpenClaw dashboard — it binds to `127.0.0.1:18789` only.
- **Tailscale** is the recommended access path; when enabled, a Docker sidecar publishes HTTPS access with `tailscale serve`.
- The Tailscale sidecar requires `/dev/net/tun` and `NET_ADMIN` / `NET_RAW` capabilities.
- Only SSH (port 22) and Tailscale UDP (41641) are opened in firewall rules.
- `gateway_token` and `dashboard_url_with_token_import` outputs contain credentials. Treat Terraform output/state as sensitive.
- **API keys** are injected into user_data / cloud-init. On AWS, user_data is accessible via the instance metadata API (IMDSv2 only, 1-hop limit enforced). For stricter security, use AWS Secrets Manager and fetch keys at boot instead.
- **SSH CIDR**: set `allowed_ssh_cidr` to your own IP (`curl ifconfig.me`) — don't leave it `0.0.0.0/0` in production.
- **EBS encryption** is enabled on both the root and data volumes.
- **IMDSv2** is enforced on EC2 (HTTP tokens required, 1-hop limit).

---

## Repository structure

```
cloud-claw/
├── .gitignore                          # Excludes *.tfvars, .terraform/, state files
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
    └── common/
        └── templates/
            └── cloud_init.yaml.tpl     # Shared bootstrap (Docker, Tailscale, OpenClaw)
```

---

## Resizing the instance

Change `aws_instance_type` (or `do_droplet_size`) and re-run `terraform apply`.

- **AWS**: Terraform stops the instance, resizes it, and restarts it. The EBS data volume is unaffected.
- **DigitalOcean**: Terraform will destroy and recreate the Droplet. The Block Storage volume persists (pass the existing volume ID/name to avoid losing data).

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

---

## Google Drive sync (optional)

The `docker-compose.yml` written by cloud-init includes a commented-out `rclone` service. To activate it:

1. On the server, run `rclone config` and follow the [Google Drive setup guide](https://rclone.org/drive/).
2. This creates `~root/.config/rclone/rclone.conf`.
3. Uncomment the `rclone` service block in `/opt/openclaw/docker-compose.yml`.
4. Run `systemctl restart openclaw` to apply the change.

The sidecar will sync `/opt/openclaw/workspace` → `gdrive:openclaw-workspace` periodically.

---

## Destroying

```bash
terraform destroy
```

> **Note**: New EBS volumes and DO volumes created by this repo are intentionally *not* set to `prevent_destroy`, so `terraform destroy` will delete them. If you want to keep your data, take a snapshot before destroying, or set `aws_existing_volume_id` / `do_existing_volume_id` to detach the volume from Terraform management first.
