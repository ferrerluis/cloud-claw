#cloud-config
# OpenClaw bootstrap  rendered by Terraform's templatefile()
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
  #  OpenClaw Docker Compose 
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
%{~ if tailscale_enabled ~}

        tailscale:
          image: tailscale/tailscale:stable
          restart: unless-stopped
          network_mode: "service:openclaw"
          depends_on:
            - openclaw
          env_file: .env
          cap_add:
            - NET_ADMIN
            - NET_RAW
          devices:
            - /dev/net/tun:/dev/net/tun
          volumes:
            - /opt/openclaw/tailscale-state:/var/lib/tailscale
            - /opt/openclaw/tailscale-bootstrap.sh:/bootstrap.sh:ro
          command: ["/bin/sh", "/bootstrap.sh"]
%{~ endif ~}

      #  Optional: Google Drive sync via rclone 
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

  #  LLM API keys 
  - path: /opt/openclaw/.env
    permissions: "0600"
    owner: root:root
    content: |
      ANTHROPIC_API_KEY=${anthropic_api_key}
      OPENAI_API_KEY=${openai_api_key}
      GROQ_API_KEY=${groq_api_key}
      GEMINI_API_KEY=${gemini_api_key}
      OPENCLAW_GATEWAY_TOKEN=${gateway_token}
%{ if tailscale_enabled }
      OPENCLAW_GATEWAY_BIND=loopback
%{ else }
      OPENCLAW_GATEWAY_BIND=lan
%{ endif }
%{ if tailscale_enabled }
      TAILSCALE_AUTH_KEY=${tailscale_auth_key}
      TAILSCALE_HOSTNAME=${project_name}
%{ endif }

%{ if tailscale_enabled }
  - path: /opt/openclaw/tailscale-bootstrap.sh
    permissions: "0700"
    owner: root:root
    content: |
      #!/bin/sh
      set -eu

      SOCK=/tmp/tailscaled.sock
      STATE_FILE=/var/lib/tailscale/tailscaled.state

      mkdir -p /var/lib/tailscale
      tailscaled --state="$STATE_FILE" --socket="$SOCK" &
      TS_PID=$!

      for _ in $(seq 1 60); do
        [ -S "$SOCK" ] && break
        sleep 1
      done

      if [ -z "$${TAILSCALE_HOSTNAME:-}" ]; then
        echo "TAILSCALE_HOSTNAME is required" >&2
        exit 1
      fi

      tailscale_up() {
        if [ -n "$${TAILSCALE_AUTH_KEY:-}" ]; then
          # Always prefer authkey when present; state file can exist before first login.
          tailscale --socket="$SOCK" up \
            --authkey="$TAILSCALE_AUTH_KEY" \
            --hostname="$TAILSCALE_HOSTNAME" \
            --accept-routes
        else
          if [ ! -s "$STATE_FILE" ]; then
            echo "TAILSCALE_AUTH_KEY is required for first bootstrap" >&2
            return 1
          fi
          tailscale --socket="$SOCK" up \
            --hostname="$TAILSCALE_HOSTNAME" \
            --accept-routes
        fi
      }

      wait_tailscale_online() {
        for _ in $(seq 1 20); do
          if tailscale --socket="$SOCK" status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
            return 0
          fi
          sleep 2
        done
        return 1
      }

      TS_ONLINE=0
      for attempt in $(seq 1 5); do
        if tailscale_up && wait_tailscale_online; then
          TS_ONLINE=1
          break
        fi
        echo "tailscale up attempt $attempt/5 did not reach online state; retrying..."
        sleep 3
      done
      if [ "$TS_ONLINE" != "1" ]; then
        echo "WARNING: Tailscale did not reach online state during bootstrap." >&2
      fi

      tailscale --socket="$SOCK" serve reset || true
      tailscale --socket="$SOCK" serve --bg 127.0.0.1:18789
      tailscale --socket="$SOCK" serve status || true

      wait "$TS_PID"
%{ endif }

  #  Systemd service 
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

  #  Volume mount script (provider-specific) 
  - path: /root/mount-openclaw-volume.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec >> /var/log/openclaw-bootstrap.log 2>&1

      mkdir -p /opt/openclaw/data /opt/openclaw/workspace /opt/openclaw/tailscale-state

%{~ if provider_type == "aws" ~}
      #  AWS: find EBS volume by NVMe serial 
      # t3/m5/c5 (Nitro) rename /dev/xvdf  /dev/nvmeXn1; stable ID = serial
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
        echo "[volume] Attempt $attempt/30  volume not visible yet, sleeping 5 s..."
        sleep 5
      done

      if [ -z "$DEVICE" ]; then
        echo "[volume] ERROR: EBS volume $VOLUME_ID not found after 150 s" >&2
        exit 1
      fi
      echo "[volume] Found EBS volume at $DEVICE"
%{~ else ~}
      #  DigitalOcean: find volume by symlink 
      VOLUME_NAME="${do_volume_name}"
      DEVICE="/dev/disk/by-id/scsi-0DO_Volume_$VOLUME_NAME"

      echo "[volume] Waiting for DO volume $VOLUME_NAME..."
      for attempt in $(seq 1 30); do
        [ -e "$DEVICE" ] && break
        echo "[volume] Attempt $attempt/30  symlink not present yet, sleeping 5 s..."
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

      #  Format if first use 
      if ! blkid "$DEVICE" > /dev/null 2>&1; then
        echo "[volume] Formatting $DEVICE as ext4..."
        mkfs.ext4 -L openclaw-data -F "$DEVICE"
      fi

      #  Mount by UUID for stable fstab entry 
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

  #  Main bootstrap script 
  - path: /root/install-openclaw.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec > >(tee -a /var/log/openclaw-bootstrap.log) 2>&1

      echo "========================================================"
      echo " OpenClaw Bootstrap  $(date)"
      echo "========================================================"

      # 1. Ensure standardized admin user exists on both providers
      ADMIN_USER="${admin_username}"
      echo "[admin] Ensuring admin user '$ADMIN_USER' exists..."
      if ! id "$ADMIN_USER" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash --groups sudo --no-user-group "$ADMIN_USER"
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

      # 3. Persistent volume
      echo "[volume] Mounting persistent storage..."
      /root/mount-openclaw-volume.sh

      # 4. Start OpenClaw
      echo "[openclaw] Enabling and starting OpenClaw service..."
      systemctl daemon-reload
      systemctl enable openclaw
      systemctl start openclaw

      wait_openclaw_healthy() {
        for attempt in $(seq 1 60); do
          OPENCLAW_CONTAINER_ID=$(docker compose -f /opt/openclaw/docker-compose.yml ps -q openclaw || true)
          if [ -n "$OPENCLAW_CONTAINER_ID" ]; then
            HEALTH_STATUS=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$OPENCLAW_CONTAINER_ID" 2>/dev/null || echo "")
            if [ "$HEALTH_STATUS" = "healthy" ] || [ "$HEALTH_STATUS" = "running" ]; then
              return 0
            fi
          fi
          sleep 3
        done
        return 1
      }

      # 5. Enable bundled channel plugins for web/CLI channel flows
      echo "[plugins] Enabling bundled channel plugins (whatsapp, telegram)..."
      PLUGINS_RESTART_NEEDED=0
      if ! wait_openclaw_healthy; then
        echo "[plugins] WARNING: OpenClaw did not become ready in time; skipping plugin enable."
      fi
      for plugin in whatsapp telegram; do
        PLUGIN_ENABLE_LOG="/tmp/openclaw-plugin-enable-$plugin.log"
        ENABLE_OK=0
        for attempt in $(seq 1 10); do
          if docker exec openclaw-openclaw-1 openclaw plugins enable "$plugin" >"$PLUGIN_ENABLE_LOG" 2>&1; then
            echo "[plugins] $plugin plugin enabled."
            ENABLE_OK=1
            PLUGINS_RESTART_NEEDED=1
            break
          fi
          sleep 3
        done
        if [ "$ENABLE_OK" != "1" ]; then
          echo "[plugins] WARNING: Failed to enable $plugin plugin after retries."
          tail -n 5 "$PLUGIN_ENABLE_LOG" || true
        fi
      done
      if [ "$PLUGINS_RESTART_NEEDED" = "1" ]; then
        systemctl restart openclaw
        wait_openclaw_healthy || echo "[plugins] WARNING: OpenClaw restart after plugin enable did not become healthy in time."
      fi

%{ if tailscale_enabled }
      # 6. Read Tailscale sidecar status and Serve URL
      echo "[tailscale] Waiting for Tailscale sidecar..."
      TS_CONTAINER_ID=""
      for attempt in $(seq 1 40); do
        TS_CONTAINER_ID=$(docker compose -f /opt/openclaw/docker-compose.yml ps -q tailscale || true)
        if [ -n "$TS_CONTAINER_ID" ] && docker exec "$TS_CONTAINER_ID" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
          break
        fi
        sleep 3
      done

      if [ -n "$TS_CONTAINER_ID" ]; then
        TAILSCALE_DNS=$(docker exec "$TS_CONTAINER_ID" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -r '.Self.DNSName // empty' || true)
        TAILSCALE_DNS="$${TAILSCALE_DNS%.}"
        OPENCLAW_CONFIG="/opt/openclaw/data/openclaw.json"
        ORIGINS_JSON=$(printf '%s\n' "https://${project_name}" "https://$TAILSCALE_DNS" "http://127.0.0.1:18789" "http://localhost:18789" | sed '/^https:\/\/$/d' | awk '!seen[$0]++' | jq -R . | jq -s .)
        if [ -f "$OPENCLAW_CONFIG" ]; then
          TMP_CONFIG=$(mktemp)
          if jq --argjson origins "$ORIGINS_JSON" --arg gateway_token "${gateway_token}" '.gateway = (.gateway // {}) | .gateway.auth = ((.gateway.auth // {}) + { mode: "token", token: $gateway_token }) | .gateway.controlUi = ((.gateway.controlUi // {}) + { allowedOrigins: $origins })' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"; then
            mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
            chown 1000:1000 "$OPENCLAW_CONFIG" || true
            echo "[openclaw] Updated gateway.auth.token and gateway.controlUi.allowedOrigins."
            systemctl restart openclaw
          else
            rm -f "$TMP_CONFIG"
            echo "[openclaw] WARNING: Failed to update gateway.controlUi.allowedOrigins."
          fi
        else
          echo "[openclaw] WARNING: $OPENCLAW_CONFIG not found; skipped allowedOrigins update."
        fi
        if [ -n "$TAILSCALE_DNS" ]; then
          echo "[tailscale] Serve URL: https://$TAILSCALE_DNS"
        else
          echo "[tailscale] Sidecar started. Check logs with: docker compose -f /opt/openclaw/docker-compose.yml logs tailscale"
        fi
      else
        echo "[tailscale] WARNING: Tailscale sidecar container not detected."
      fi
%{ endif }

      echo "========================================================"
      echo " Bootstrap complete  $(date)"
%{ if tailscale_enabled }
      echo " Dashboard: https://${project_name}  (via Tailscale Serve sidecar)"
%{ else }
      echo " Dashboard: ssh -L 18789:127.0.0.1:18789 ${admin_username}@<IP>"
%{ endif }
      echo " Logs:      journalctl -u openclaw -f"
      echo "========================================================"

runcmd:
  - /root/install-openclaw.sh
