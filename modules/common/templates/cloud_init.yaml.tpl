#cloud-config
# OpenClaw bootstrap — rendered by Terraform's templatefile()
# Provider: ${provider_type}

packages:
  - curl
  - git
  - ca-certificates
  - gnupg
  - lsb-release
  - nvme-cli
  - jq

write_files:
  # ── OpenClaw Docker Compose ────────────────────────────────────────────────
  - path: /opt/openclaw/docker-compose.yml
    permissions: "0644"
    owner: root:root
    content: |
      services:
        openclaw:
          image: ghcr.io/openclaw/openclaw:${openclaw_version}
          restart: unless-stopped
          env_file: .env
          ports:
            - "127.0.0.1:18789:18789"
            - "127.0.0.1:18793:18793"
          volumes:
            - /opt/openclaw/data:/home/node/.openclaw
            - /opt/openclaw/workspace:/home/node/openclaw/workspace

      # ── Optional: Google Drive sync via rclone ─────────────────────────────
      # Uncomment and configure rclone (https://rclone.org/drive/) to sync
      # the workspace to Google Drive. See README for full instructions.
      #  rclone:
      #    image: rclone/rclone:latest
      #    restart: unless-stopped
      #    depends_on: [openclaw]
      #    volumes:
      #      - /opt/openclaw/workspace:/data
      #      - /root/.config/rclone:/config/rclone:ro
      #    command:
      #      - sync
      #      - /data
      #      - gdrive:openclaw-workspace
      #      - --transfers=4
      #      - --log-level=INFO

  # ── LLM API keys ──────────────────────────────────────────────────────────
  - path: /opt/openclaw/.env
    permissions: "0600"
    owner: root:root
    content: |
      ANTHROPIC_API_KEY=${anthropic_api_key}
      OPENAI_API_KEY=${openai_api_key}
      GROQ_API_KEY=${groq_api_key}
      GEMINI_API_KEY=${gemini_api_key}

  # ── Systemd service ───────────────────────────────────────────────────────
  - path: /etc/systemd/system/openclaw.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=OpenClaw AI Assistant
      Documentation=https://github.com/openclaw/openclaw
      Requires=docker.service
      After=docker.service network-online.target

      [Service]
      Type=simple
      WorkingDirectory=/opt/openclaw
      ExecStartPre=/usr/bin/docker compose pull --quiet
      ExecStart=/usr/bin/docker compose up --remove-orphans
      ExecStop=/usr/bin/docker compose down
      Restart=on-failure
      RestartSec=15
      TimeoutStartSec=180

      [Install]
      WantedBy=multi-user.target

  # ── Volume mount script (provider-specific) ────────────────────────────────
  - path: /root/mount-openclaw-volume.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec >> /var/log/openclaw-bootstrap.log 2>&1

      mkdir -p /opt/openclaw/data /opt/openclaw/workspace

%{~ if provider_type == "aws" ~}
      # ── AWS: find EBS volume by NVMe serial ───────────────────────────────
      # t3/m5/c5 (Nitro) rename /dev/xvdf → /dev/nvmeXn1; stable ID = serial
      VOLUME_ID="${ebs_volume_id}"
      SERIAL=$(echo "$VOLUME_ID" | tr -d '-')

      echo "[volume] Waiting for EBS volume $VOLUME_ID (serial $SERIAL)..."
      DEVICE=""
      for attempt in $(seq 1 30); do
        for dev in /dev/nvme*n1; do
          [ -b "$dev" ] || continue
          if nvme id-ctrl "$dev" 2>/dev/null | grep -qi "$SERIAL"; then
            DEVICE="$dev"
            break 2
          fi
        done
        echo "[volume] Attempt $attempt/30 — volume not visible yet, sleeping 5 s..."
        sleep 5
      done

      if [ -z "$DEVICE" ]; then
        echo "[volume] ERROR: EBS volume $VOLUME_ID not found after 150 s" >&2
        exit 1
      fi
      echo "[volume] Found EBS volume at $DEVICE"
%{~ else ~}
      # ── DigitalOcean: find volume by symlink ──────────────────────────────
      VOLUME_NAME="${do_volume_name}"
      DEVICE="/dev/disk/by-id/scsi-0DO_Volume_$VOLUME_NAME"

      echo "[volume] Waiting for DO volume $VOLUME_NAME..."
      for attempt in $(seq 1 30); do
        [ -e "$DEVICE" ] && break
        echo "[volume] Attempt $attempt/30 — symlink not present yet, sleeping 5 s..."
        sleep 5
      done

      if [ ! -e "$DEVICE" ]; then
        echo "[volume] ERROR: DO volume $VOLUME_NAME not found after 150 s" >&2
        exit 1
      fi
      echo "[volume] Found DO volume at $DEVICE"

      # Unmount DO auto-mount if the volume was attached before this script ran
      if CURRENT_MOUNT=$(findmnt -n -o TARGET --source "$DEVICE" 2>/dev/null); then
        if [ "$CURRENT_MOUNT" != "/opt/openclaw/data" ]; then
          echo "[volume] Unmounting DO auto-mount at $CURRENT_MOUNT"
          umount "$CURRENT_MOUNT" || true
        fi
      fi
%{~ endif ~}

      # ── Format if first use ───────────────────────────────────────────────
      if ! blkid "$DEVICE" > /dev/null 2>&1; then
        echo "[volume] Formatting $DEVICE as ext4..."
        mkfs.ext4 -L openclaw-data -F "$DEVICE"
      fi

      # ── Mount by UUID for stable fstab entry ─────────────────────────────
      UUID=$(blkid -s UUID -o value "$DEVICE")
      echo "[volume] UUID: $UUID"

      if ! mountpoint -q /opt/openclaw/data; then
        mount -o defaults,nofail UUID="$UUID" /opt/openclaw/data
      fi

      if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID /opt/openclaw/data ext4 defaults,nofail 0 2" >> /etc/fstab
      fi

      # OpenClaw runs as uid/gid 1000 (node user inside the container)
      chown -R 1000:1000 /opt/openclaw/data /opt/openclaw/workspace
      echo "[volume] Mount complete."

  # ── Main bootstrap script ─────────────────────────────────────────────────
  - path: /root/install-openclaw.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec > >(tee -a /var/log/openclaw-bootstrap.log) 2>&1

      echo "========================================================"
      echo " OpenClaw Bootstrap — $(date)"
      echo "========================================================"

      # 1. Ensure standardized admin user exists on both providers
      ADMIN_USER="${admin_username}"
      echo "[admin] Ensuring admin user '$ADMIN_USER' exists..."
      if ! id "$ADMIN_USER" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash --groups sudo "$ADMIN_USER"
      fi

      ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
      if [ -z "$ADMIN_HOME" ]; then
        echo "[admin] ERROR: Could not resolve home directory for user $ADMIN_USER" >&2
        exit 1
      fi

      install -d -m 700 "$ADMIN_HOME/.ssh"
      touch "$ADMIN_HOME/.ssh/authorized_keys"
      if ! grep -qxF '${admin_ssh_public_key}' "$ADMIN_HOME/.ssh/authorized_keys"; then
        echo '${admin_ssh_public_key}' >> "$ADMIN_HOME/.ssh/authorized_keys"
      fi
      chown -R "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh"
      chmod 700 "$ADMIN_HOME/.ssh"
      chmod 600 "$ADMIN_HOME/.ssh/authorized_keys"
      echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-openclaw-admin
      chmod 440 /etc/sudoers.d/90-openclaw-admin
      echo "[admin] Done."

      # 2. Docker
      echo "[docker] Installing Docker..."
      curl -fsSL https://get.docker.com | sh
      systemctl enable --now docker
      usermod -aG docker "$ADMIN_USER"
      echo "[docker] Done."

%{~ if tailscale_enabled ~}
      # 3. Tailscale
      echo "[tailscale] Installing Tailscale..."
      curl -fsSL https://tailscale.com/install.sh | sh
      tailscale up \
        --authkey="${tailscale_auth_key}" \
        --hostname="${project_name}" \
        --accept-routes
      echo "[tailscale] Up. Hostname: ${project_name}"
      TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
      echo "[tailscale] IP: $TAILSCALE_IP"
%{~ endif ~}

      # 4. Persistent volume
      echo "[volume] Mounting persistent storage..."
      /root/mount-openclaw-volume.sh

      # 5. Start OpenClaw
      echo "[openclaw] Enabling and starting OpenClaw service..."
      systemctl daemon-reload
      systemctl enable openclaw
      systemctl start openclaw

      echo "========================================================"
      echo " Bootstrap complete — $(date)"
%{~ if tailscale_enabled ~}
      echo " Dashboard: http://${project_name}:18789  (via Tailscale)"
%{~ else ~}
      echo " Dashboard: ssh -L 18789:127.0.0.1:18789 ${admin_username}@<IP>"
%{~ endif ~}
      echo " Logs:      journalctl -u openclaw -f"
      echo "========================================================"

runcmd:
  - /root/install-openclaw.sh
