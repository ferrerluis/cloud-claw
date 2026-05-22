#cloud-config
# AgentStack bootstrap rendered by Terraform's templatefile()
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
  #  AgentStack Docker Compose
  - path: /opt/agent-stack/docker-compose.yml
    permissions: "0644"
    owner: root:root
    content: |
      services:
%{ if openclaw_enabled }
        openclaw:
          image: ghcr.io/openclaw/openclaw:${openclaw_version}
          restart: unless-stopped
          env_file: .env
          ports:
            - "127.0.0.1:18789:18789"
            - "127.0.0.1:18793:18793"
          volumes:
            - /opt/agent-stack/data/openclaw:/home/node/.openclaw
%{~ if openai_codex_auth_json_base64 != "" ~}
            - /opt/agent-stack/codex:/home/node/.codex
%{~ endif ~}
          healthcheck:
            test: ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
            interval: 30s
            timeout: 10s
            retries: ${openclaw_health_retries}
            start_period: ${openclaw_health_start_period_seconds}s
%{ endif }
%{ if hermes_enabled }

        hermes:
          image: ${hermes_image}
          restart: unless-stopped
          command: gateway run
          env_file: .env
          ports:
            - "127.0.0.1:8642:8642"
            - "127.0.0.1:9119:9119"
          volumes:
            - /opt/agent-stack/data/hermes:/opt/data
          environment:
            HERMES_DASHBOARD: "${hermes_dashboard_enabled ? "1" : "0"}"
            HERMES_DASHBOARD_HOST: "0.0.0.0"
            HERMES_DASHBOARD_PORT: "9119"
            API_SERVER_ENABLED: "${hermes_api_server_enabled ? "true" : "false"}"
            API_SERVER_HOST: "0.0.0.0"
            API_SERVER_KEY: "${hermes_api_server_key}"
            API_SERVER_CORS_ORIGINS: "*"
%{ endif }
%{ if local_postgres_enabled }

        postgres:
          image: ${postgres_image}
          restart: unless-stopped
          env_file: .env
          environment:
            POSTGRES_DB: "${postgres_database}"
            POSTGRES_USER: "${postgres_user}"
            POSTGRES_PASSWORD: "${postgres_password}"
            PGDATA: /var/lib/postgresql/data/pgdata
          volumes:
            - /opt/agent-stack/data/postgres:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ${postgres_user} -d ${postgres_database}"]
            interval: 30s
            timeout: 10s
            retries: 8
%{ endif }
%{ if n8n_enabled }

        n8n:
          image: ${n8n_image}
          restart: unless-stopped
          env_file: .env
          ports:
            - "127.0.0.1:5678:5678"
          volumes:
            - /opt/agent-stack/data/n8n:/home/node/.n8n
%{ if local_postgres_enabled }
          depends_on:
            postgres:
              condition: service_healthy
%{ endif }
%{ endif }
%{ if caddy_enabled }

        caddy:
          image: caddy:2-alpine
          restart: unless-stopped
          env_file: .env
          ports:
            - "80:80"
            - "443:443"
          volumes:
            - /opt/agent-stack/Caddyfile:/etc/caddy/Caddyfile:ro
            - /opt/agent-stack/data/caddy/data:/data
            - /opt/agent-stack/data/caddy/config:/config
%{ endif }
%{ if tailscale_enabled }

        tailscale:
          image: tailscale/tailscale:stable
          restart: unless-stopped
          network_mode: "host"
          env_file: .env
          cap_add:
            - NET_ADMIN
            - NET_RAW
          devices:
            - /dev/net/tun:/dev/net/tun
          volumes:
            - /opt/agent-stack/tailscale-state:/var/lib/tailscale
            - /opt/agent-stack/tailscale-bootstrap.sh:/bootstrap.sh:ro
          command: ["/bin/sh", "/bootstrap.sh"]
%{ endif }

      #  Optional: Google Drive sync via rclone
      # Uncomment and configure rclone (https://rclone.org/drive/) to sync
      # the workspace to Google Drive. See README for full instructions.
      #  rclone:
      #    image: rclone/rclone:latest
      #    restart: unless-stopped
      #    depends_on: [openclaw]
      #    volumes:
      #      - /opt/agent-stack/data/openclaw/workspace:/data
      #      - /root/.config/rclone:/config/rclone:ro
      #    command:
      #      - sync
      #      - /data
      #      - gdrive:openclaw-workspace
      #      - --transfers=4
      #      - --log-level=INFO

  #  LLM API keys 
  - path: /opt/agent-stack/.env
    permissions: "0600"
    owner: root:root
    content: |
      ANTHROPIC_API_KEY=${anthropic_api_key}
      ANTHROPIC_AUTH_KEY=${anthropic_auth_key}
      OPENAI_API_KEY=${openai_api_key}
      GROQ_API_KEY=${groq_api_key}
      GEMINI_API_KEY=${gemini_api_key}
      TELEGRAM_BOT_TOKEN=${telegram_bot_token}
      OPENCLAW_GATEWAY_TOKEN=${gateway_token}
      OPENCLAW_ENABLED=${openclaw_enabled}
      HERMES_ENABLED=${hermes_enabled}
      N8N_ENABLED=${n8n_enabled}
      LOCAL_POSTGRES_ENABLED=${local_postgres_enabled}
      CADDY_ENABLED=${caddy_enabled}
      NODE_OPTIONS=${openclaw_node_options}
%{ if tailscale_enabled }
      OPENCLAW_GATEWAY_BIND=loopback
%{ else }
      OPENCLAW_GATEWAY_BIND=lan
%{ endif }
%{ if tailscale_enabled }
      TAILSCALE_AUTH_KEY=${tailscale_auth_key}
      TAILSCALE_HOSTNAME=${project_name}
%{ endif }
      HERMES_DASHBOARD=${hermes_dashboard_enabled ? "1" : "0"}
      HERMES_DASHBOARD_HOST=0.0.0.0
      HERMES_DASHBOARD_PORT=9119
      API_SERVER_ENABLED=${hermes_api_server_enabled}
      API_SERVER_HOST=0.0.0.0
      API_SERVER_KEY=${hermes_api_server_key}
      API_SERVER_CORS_ORIGINS=*
      N8N_ENCRYPTION_KEY=${n8n_encryption_key}
      GENERIC_TIMEZONE=${n8n_generic_timezone}
      DB_TYPE=postgresdb
      DB_POSTGRESDB_HOST=${n8n_postgres_host}
      DB_POSTGRESDB_PORT=${n8n_postgres_port}
      DB_POSTGRESDB_DATABASE=${n8n_postgres_database}
      DB_POSTGRESDB_USER=${n8n_postgres_user}
      DB_POSTGRESDB_PASSWORD=${n8n_postgres_password}
      DB_POSTGRESDB_SSL_ENABLED=${n8n_postgres_ssl_enabled}
      POSTGRES_DB=${postgres_database}
      POSTGRES_USER=${postgres_user}
      POSTGRES_PASSWORD=${postgres_password}
%{ if caddy_enabled && n8n_domain != "" }
      N8N_HOST=${n8n_domain}
      N8N_PORT=5678
      N8N_PROTOCOL=https
      WEBHOOK_URL=https://${n8n_domain}/
      N8N_EDITOR_BASE_URL=https://${n8n_domain}/
      N8N_PROXY_HOPS=1
%{ endif }
      UI_AUTH_USERNAME=${ui_auth_username}
      UI_AUTH_PASSWORD=${ui_auth_password}

%{ if caddy_enabled }
  - path: /opt/agent-stack/Caddyfile.template
    permissions: "0600"
    owner: root:root
    content: |
%{ if acme_email != "" }
      {
        email ${acme_email}
      }

%{ endif }
      (agentstack_ui_auth) {
        basic_auth {
          ${ui_auth_username} __UI_AUTH_HASH__
        }
      }
%{ if openclaw_enabled && openclaw_domain != "" }

      ${openclaw_domain} {
        import agentstack_ui_auth
        reverse_proxy openclaw:18789
      }
%{ endif }
%{ if hermes_enabled && hermes_domain != "" }

      ${hermes_domain} {
        import agentstack_ui_auth
        reverse_proxy hermes:9119
      }
%{ endif }
%{ if n8n_enabled && n8n_domain != "" }

      ${n8n_domain} {
%{ if n8n_public_webhooks_enabled }
        @n8n_webhooks path /webhook* /webhook-test*
        handle @n8n_webhooks {
          reverse_proxy n8n:5678
        }

%{ endif }
        handle {
          import agentstack_ui_auth
          reverse_proxy n8n:5678
        }
      }
%{ endif }
%{ endif }

  #  Starter workspace templates (seeded create-if-missing by install script)
  - path: /opt/agent-stack/templates/SOUL.balanced.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_soul_balanced_md, "\n", "\n      ")}

  - path: /opt/agent-stack/templates/SOUL.builder.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_soul_builder_md, "\n", "\n      ")}

  - path: /opt/agent-stack/templates/SOUL.researcher.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_soul_researcher_md, "\n", "\n      ")}

  - path: /opt/agent-stack/templates/AGENTS.default.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_agents_md, "\n", "\n      ")}

  - path: /opt/agent-stack/templates/TOOLS.default.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_tools_md, "\n", "\n      ")}

  - path: /opt/agent-stack/templates/USER.default.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_user_md, "\n", "\n      ")}


%{ if tailscale_enabled }
  - path: /opt/agent-stack/tailscale-bootstrap.sh
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
      if [ "$${OPENCLAW_ENABLED:-false}" = "true" ]; then
        tailscale --socket="$SOCK" serve --bg 127.0.0.1:18789
        tailscale --socket="$SOCK" serve status || true
      else
        echo "OpenClaw is disabled; Tailscale Serve route was not configured."
      fi

      wait "$TS_PID"
%{ endif }

  #  Layout migrator
  - path: /usr/local/bin/agent-stack-migrate-layout
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      APP_ROOT="$${AGENT_STACK_APP_ROOT:-/opt/agent-stack}"
      DATA_ROOT="$${AGENT_STACK_DATA_ROOT:-$APP_ROOT/data}"
      LEGACY_ROOT="$${AGENT_STACK_LEGACY_ROOT:-/opt/openclaw}"
      LEGACY_SERVICES="$DATA_ROOT/services"
      MARKER="$DATA_ROOT/.agent-stack-layout-version"

      log() {
        echo "[layout] $*"
      }

      ensure_dirs() {
        install -d -m 0755 "$APP_ROOT" "$DATA_ROOT"
        install -d -m 0755 \
          "$DATA_ROOT/openclaw" \
          "$DATA_ROOT/hermes" \
          "$DATA_ROOT/n8n" \
          "$DATA_ROOT/postgres" \
          "$DATA_ROOT/caddy/data" \
          "$DATA_ROOT/caddy/config" \
          "$APP_ROOT/tailscale-state"
      }

      move_children() {
        local src="$1"
        local dest="$2"
        [ -d "$src" ] || return 0
        install -d -m 0755 "$dest"
        shopt -s dotglob nullglob
        local child
        for child in "$src"/*; do
          local base
          base="$(basename "$child")"
          if [ -e "$dest/$base" ]; then
            log "Keeping existing $dest/$base; leaving legacy $child in place."
            continue
          fi
          mv "$child" "$dest/"
        done
        shopt -u dotglob nullglob
        rmdir "$src" 2>/dev/null || true
      }

      migrate_legacy_volume_layout() {
        [ -d "$DATA_ROOT" ] || return 0
        if [ -f "$MARKER" ]; then
          log "AgentStack data layout already present."
          return 0
        fi

        if [ ! -f "$DATA_ROOT/openclaw.json" ] && [ ! -d "$DATA_ROOT/workspace" ] && [ ! -d "$DATA_ROOT/services" ]; then
          log "Fresh AgentStack data volume detected."
          return 0
        fi

        log "Migrating legacy /opt/openclaw/data payload into peer service layout."
        install -d -m 0755 "$DATA_ROOT/openclaw"

        if [ -d "$LEGACY_SERVICES/hermes" ]; then
          move_children "$LEGACY_SERVICES/hermes" "$DATA_ROOT/hermes"
        fi
        if [ -d "$LEGACY_SERVICES/n8n" ]; then
          move_children "$LEGACY_SERVICES/n8n" "$DATA_ROOT/n8n"
        fi
        if [ -d "$LEGACY_SERVICES/postgres" ]; then
          move_children "$LEGACY_SERVICES/postgres" "$DATA_ROOT/postgres"
        fi
        if [ -d "$LEGACY_SERVICES/caddy" ]; then
          move_children "$LEGACY_SERVICES/caddy" "$DATA_ROOT/caddy"
        fi
        rmdir "$LEGACY_SERVICES" 2>/dev/null || true

        shopt -s dotglob nullglob
        local child
        for child in "$DATA_ROOT"/*; do
          local base
          base="$(basename "$child")"
          case "$base" in
            openclaw|hermes|n8n|postgres|caddy|lost+found)
              continue
              ;;
          esac
          if [ -e "$DATA_ROOT/openclaw/$base" ]; then
            log "Keeping existing $DATA_ROOT/openclaw/$base; leaving $child in place."
            continue
          fi
          mv "$child" "$DATA_ROOT/openclaw/"
        done
        shopt -u dotglob nullglob
      }

      ensure_legacy_symlinks() {
        if [ ! -e "$DATA_ROOT/openclaw.json" ]; then
          ln -s openclaw/openclaw.json "$DATA_ROOT/openclaw.json" 2>/dev/null || true
        fi
        if [ ! -e "$DATA_ROOT/workspace" ]; then
          ln -s openclaw/workspace "$DATA_ROOT/workspace" 2>/dev/null || true
        fi

        if [ -L "$LEGACY_ROOT" ]; then
          return 0
        fi
        if [ ! -e "$LEGACY_ROOT" ]; then
          ln -s "$APP_ROOT" "$LEGACY_ROOT"
          return 0
        fi
        if [ -d "$LEGACY_ROOT" ] && [ -z "$(find "$LEGACY_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
          rmdir "$LEGACY_ROOT"
          ln -s "$APP_ROOT" "$LEGACY_ROOT"
          return 0
        fi
        log "Leaving existing $LEGACY_ROOT in place; it is not safe to replace with a symlink."
      }

      fix_service_ownership() {
        chown -R 1000:1000 "$DATA_ROOT/openclaw" || true
        chown -R 10000:10000 "$DATA_ROOT/hermes" || true
        chown -R 1000:1000 "$DATA_ROOT/n8n" || true
      }

      ensure_dirs
      migrate_legacy_volume_layout
      ensure_dirs
      ensure_legacy_symlinks
      fix_service_ownership
      printf '1\n' > "$MARKER"
      log "Layout ready at $DATA_ROOT."

  #  Systemd service
  - path: /etc/systemd/system/agent-stack.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=AgentStack
      Documentation=https://github.com/openclaw/openclaw
      Requires=docker.service
      After=docker.service network-online.target

      [Service]
      Type=simple
      WorkingDirectory=/opt/agent-stack
      ExecStartPre=/usr/local/bin/agent-stack-migrate-layout
      ExecStartPre=/usr/bin/docker compose pull --quiet
      ExecStart=/usr/bin/docker compose up --remove-orphans
      ExecStop=/usr/bin/docker compose down
      Restart=on-failure
      RestartSec=15
      TimeoutStartSec=180

      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/openclaw.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Compatibility wrapper for AgentStack
      Requires=agent-stack.service
      After=agent-stack.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/bin/systemctl start agent-stack.service
      ExecStop=/bin/systemctl stop agent-stack.service

      [Install]
      WantedBy=multi-user.target

%{ if tailscale_enabled }
  #  Tailscale watchdog (auto-heal sidecar route/online regressions) 
  - path: /usr/local/bin/agent-stack-tailscale-watchdog
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      TS_CONTAINER=$(docker compose -f /opt/agent-stack/docker-compose.yml ps -q tailscale 2>/dev/null || true)
      if [ -z "$TS_CONTAINER" ]; then
        exit 0
      fi

      ONLINE=$(docker exec "$TS_CONTAINER" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -r '.Self.Online // false' || echo false)
      ROUTE_LINES=$(docker exec "$TS_CONTAINER" sh -lc 'cat /proc/net/route | wc -l' 2>/dev/null || echo 0)
      if [ "$ONLINE" != "true" ] || [ "$ROUTE_LINES" -le 1 ]; then
        logger -t agent-stack-tailscale-watchdog "restarting tailscale sidecar (online=$ONLINE routes=$ROUTE_LINES)"
        docker restart "$TS_CONTAINER" >/dev/null
      fi

  - path: /etc/systemd/system/agent-stack-tailscale-watchdog.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=AgentStack Tailscale watchdog
      After=docker.service

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/agent-stack-tailscale-watchdog

  - path: /etc/systemd/system/agent-stack-tailscale-watchdog.timer
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Run AgentStack Tailscale watchdog every minute

      [Timer]
      OnBootSec=45s
      OnUnitActiveSec=60s
      Unit=agent-stack-tailscale-watchdog.service

      [Install]
      WantedBy=timers.target
%{ endif }

  #  Volume mount script (provider-specific) 
  - path: /root/mount-agent-stack-volume.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec >> /var/log/openclaw-bootstrap.log 2>&1

      mkdir -p \
        /opt/agent-stack/data \
        /opt/agent-stack/tailscale-state

%{ if provider_type == "aws" }
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
%{ else }
%{ if provider_type == "hetzner" }
      # Hetzner Cloud: find volume by stable ID symlink
      VOLUME_ID="${hcloud_volume_id}"
      DEVICE="/dev/disk/by-id/scsi-0HC_Volume_$VOLUME_ID"

      echo "[volume] Waiting for Hetzner Cloud volume $VOLUME_ID..."
      for attempt in $(seq 1 30); do
        [ -e "$DEVICE" ] && break
        echo "[volume] Attempt $attempt/30  symlink not present yet, sleeping 5 s..."
        sleep 5
      done

      if [ ! -e "$DEVICE" ]; then
        echo "[volume] ERROR: Hetzner Cloud volume $VOLUME_ID not found after 150 s" >&2
        exit 1
      fi
      echo "[volume] Found Hetzner Cloud volume at $DEVICE"
%{ else }
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
        if [ "$CURRENT_MOUNT" != "/opt/agent-stack/data" ]; then
          echo "[volume] Unmounting DO auto-mount at $CURRENT_MOUNT"
          umount "$CURRENT_MOUNT" || true
        fi
      fi
%{ endif }
%{ endif }

      #  Format if first use 
      if ! blkid "$DEVICE" > /dev/null 2>&1; then
        echo "[volume] Formatting $DEVICE as ext4..."
        mkfs.ext4 -L agent-stack-data -F "$DEVICE"
      fi

      #  Mount by UUID for stable fstab entry 
      UUID=$(blkid -s UUID -o value "$DEVICE")
      echo "[volume] UUID: $UUID"

      if mountpoint -q /opt/openclaw/data; then
        echo "[volume] Unmounting legacy mountpoint /opt/openclaw/data"
        umount /opt/openclaw/data || true
      fi

      if ! mountpoint -q /opt/agent-stack/data; then
        mount -o defaults,nofail UUID="$UUID" /opt/agent-stack/data
      fi

      sed -i "\|UUID=$UUID /opt/openclaw/data |d" /etc/fstab || true
      if ! grep -qE "UUID=$UUID[[:space:]]+/opt/agent-stack/data[[:space:]]" /etc/fstab; then
        echo "UUID=$UUID /opt/agent-stack/data ext4 defaults,nofail 0 2" >> /etc/fstab
      fi

      echo "[volume] Mount complete."

  #  Main bootstrap script 
  - path: /root/install-agent-stack.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec > >(tee -a /var/log/openclaw-bootstrap.log) 2>&1
      NEEDS_RESTART=0

      echo "========================================================"
      echo " AgentStack Bootstrap  $(date)"
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
      /root/mount-agent-stack-volume.sh
      /usr/local/bin/agent-stack-migrate-layout

      OPENCLAW_ENABLED='${openclaw_enabled}'
      HERMES_ENABLED='${hermes_enabled}'
      N8N_ENABLED='${n8n_enabled}'
      LOCAL_POSTGRES_ENABLED='${local_postgres_enabled}'
      CADDY_ENABLED='${caddy_enabled}'
      UI_AUTH_PASSWORD='${ui_auth_password}'

      configure_caddyfile() {
        if [ "$CADDY_ENABLED" != "true" ]; then
          echo "[caddy] Skipped (public_domain_enabled=false)."
          return 0
        fi

        if [ ! -f /opt/agent-stack/Caddyfile.template ]; then
          echo "[caddy] WARNING: /opt/agent-stack/Caddyfile.template missing; public domains will not start."
          return 1
        fi

        echo "[caddy] Rendering Caddyfile with hashed basic-auth password..."
        CADDY_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$UI_AUTH_PASSWORD")
        sed "s|__UI_AUTH_HASH__|$CADDY_HASH|g" /opt/agent-stack/Caddyfile.template > /opt/agent-stack/Caddyfile
        chmod 600 /opt/agent-stack/Caddyfile
        echo "[caddy] Caddyfile rendered."
      }

      configure_caddyfile

      OPENAI_CODEX_AUTH_JSON_BASE64='${openai_codex_auth_json_base64}'

      sync_openai_codex_auth() {
        if [ -z "$OPENAI_CODEX_AUTH_JSON_BASE64" ]; then
          echo "[openai-codex] No Codex CLI auth import configured."
          return 0
        fi

        echo "[openai-codex] Importing Codex CLI auth into /opt/agent-stack/codex/auth.json..."
        install -d -m 700 -o 1000 -g 1000 /opt/agent-stack/codex
        printf '%s' "$OPENAI_CODEX_AUTH_JSON_BASE64" | base64 --decode > /opt/agent-stack/codex/auth.json
        chown 1000:1000 /opt/agent-stack/codex/auth.json
        chmod 600 /opt/agent-stack/codex/auth.json
      }

      sync_openai_codex_auth

      # 4. Optional swap (recommended for small RAM nodes)
      configure_swap() {
        local swap_mb=${openclaw_swap_size_mb}
        if [ "$swap_mb" -le 0 ]; then
          echo "[swap] Skipped (openclaw_swap_size_mb=$swap_mb)."
          return 0
        fi

        if swapon --show --noheadings 2>/dev/null | grep -q .; then
          echo "[swap] Swap already enabled:"
          swapon --show || true
          return 0
        fi

        echo "[swap] Configuring /swapfile (${openclaw_swap_size_mb} MB)..."
        if [ ! -f /swapfile ]; then
          if command -v fallocate >/dev/null 2>&1; then
            fallocate -l ${openclaw_swap_size_mb}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=${openclaw_swap_size_mb} status=none
          else
            dd if=/dev/zero of=/swapfile bs=1M count=${openclaw_swap_size_mb} status=none
          fi
        fi

        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || true
        swapon /swapfile
        if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
          echo "/swapfile none swap sw 0 0" >> /etc/fstab
        fi
        echo "vm.swappiness=10" > /etc/sysctl.d/99-openclaw-memory.conf
        sysctl -p /etc/sysctl.d/99-openclaw-memory.conf >/dev/null || true
        swapon --show || true
      }

      configure_swap

      OPENCLAW_CONFIG="/opt/agent-stack/data/openclaw/openclaw.json"
      OPENCLAW_CONFIG_MODE_INPUT="${openclaw_config_mode}"
      PREEXISTING_OPENCLAW_CONFIG=0
      if [ -f "$OPENCLAW_CONFIG" ]; then
        PREEXISTING_OPENCLAW_CONFIG=1
      fi
      case "$OPENCLAW_CONFIG_MODE_INPUT" in
        manage|preserve)
          OPENCLAW_CONFIG_MODE_EFFECTIVE="$OPENCLAW_CONFIG_MODE_INPUT"
          ;;
        auto)
          if [ "$PREEXISTING_OPENCLAW_CONFIG" = "1" ]; then
            OPENCLAW_CONFIG_MODE_EFFECTIVE="preserve"
          else
            OPENCLAW_CONFIG_MODE_EFFECTIVE="manage"
          fi
          ;;
        *)
          OPENCLAW_CONFIG_MODE_EFFECTIVE="manage"
          ;;
      esac
      AGENT_CHANNEL="${agent_channel}"
      MODEL_PROVIDERS_ENABLED_JSON='${model_providers_enabled_json}'
      DEFAULT_MODEL_REF='${default_model}'
      FALLBACK_MODELS_JSON='${fallback_models_json}'
      TELEGRAM_ALLOW_FROM_JSON='${telegram_allow_from_json}'
      STARTER_SOUL_PROFILE='${starter_soul_profile}'
      SHOULD_SEED_STARTER_FILES='${seed_starter_workspace_files}'

      echo "[config] openclaw_config_mode=$OPENCLAW_CONFIG_MODE_INPUT effective=$OPENCLAW_CONFIG_MODE_EFFECTIVE preexisting_config=$PREEXISTING_OPENCLAW_CONFIG"
      echo "[config] agent_channel=$AGENT_CHANNEL starter_soul_profile=$STARTER_SOUL_PROFILE"

      seed_file_if_missing() {
        local source="$1"
        local destination="$2"
        if [ -f "$destination" ]; then
          echo "[starter] Keeping existing file: $destination"
          return 0
        fi
        install -D -m 0644 "$source" "$destination"
        chown 1000:1000 "$destination" || true
        echo "[starter] Seeded: $destination"
      }

      seed_starter_workspace_files() {
        if [ "$SHOULD_SEED_STARTER_FILES" != "true" ]; then
          echo "[starter] Skipped (seed_starter_workspace_files=$SHOULD_SEED_STARTER_FILES)."
          return 0
        fi

        local workspace_dir="/opt/agent-stack/data/openclaw/workspace"
        local soul_source="/opt/agent-stack/templates/SOUL.balanced.md"
        case "$STARTER_SOUL_PROFILE" in
          builder)
            soul_source="/opt/agent-stack/templates/SOUL.builder.md"
            ;;
          researcher)
            soul_source="/opt/agent-stack/templates/SOUL.researcher.md"
            ;;
        esac

        mkdir -p "$workspace_dir"
        chown 1000:1000 "$workspace_dir" || true
        seed_file_if_missing "$soul_source" "$workspace_dir/SOUL.md"
        seed_file_if_missing "/opt/agent-stack/templates/AGENTS.default.md" "$workspace_dir/AGENTS.md"
        seed_file_if_missing "/opt/agent-stack/templates/TOOLS.default.md" "$workspace_dir/TOOLS.md"
        seed_file_if_missing "/opt/agent-stack/templates/USER.default.md" "$workspace_dir/USER.md"
      }

      # 5. Start AgentStack
      echo "[stack] Enabling and starting AgentStack stack service..."
      systemctl daemon-reload
      systemctl enable agent-stack
      systemctl enable openclaw
%{ if tailscale_enabled }
      systemctl enable --now agent-stack-tailscale-watchdog.timer
%{ endif }
      systemctl start agent-stack
      systemctl start openclaw || true

      wait_openclaw_healthy() {
        if [ "$OPENCLAW_ENABLED" != "true" ]; then
          return 1
        fi
        for attempt in $(seq 1 60); do
          OPENCLAW_CONTAINER_ID=$(docker compose -f /opt/agent-stack/docker-compose.yml ps -q openclaw || true)
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

      wait_for_openclaw_config() {
        for attempt in $(seq 1 60); do
          [ -f "$OPENCLAW_CONFIG" ] && return 0
          sleep 2
        done
        return 1
      }

      mark_openclaw_restart_needed() {
        NEEDS_RESTART=1
      }

      # Prevent long-running/interactive CLI calls from hanging bootstrap forever.
      run_openclaw_cli() {
        if command -v timeout >/dev/null 2>&1; then
          timeout "$${OPENCLAW_CLI_TIMEOUT_SECONDS:-30}" docker compose -f /opt/agent-stack/docker-compose.yml exec -T openclaw openclaw "$@"
        else
          docker compose -f /opt/agent-stack/docker-compose.yml exec -T openclaw openclaw "$@"
        fi
      }

      OPENCLAW_ENV_FILE="/opt/agent-stack/.env"
      env_value() {
        local key="$1"
        sed -n "s/^$key=//p" "$OPENCLAW_ENV_FILE" | tail -n 1 || true
      }
      has_env_key() {
        local key="$1"
        local value
        value=$(env_value "$key")
        [ -n "$value" ]
      }

      # Seed starter files only after OpenClaw has initialized once, so any
      # OpenClaw-native first-run files are preserved and take precedence.
      if [ "$OPENCLAW_ENABLED" = "true" ]; then
        if wait_openclaw_healthy; then
          seed_starter_workspace_files
        else
          echo "[starter] WARNING: OpenClaw did not become healthy; skipping starter file seed to avoid clobbering first-run files."
        fi
      else
        echo "[starter] OpenClaw is disabled; skipping OpenClaw starter files."
      fi

      config_customizations_enabled() {
        [ "$OPENCLAW_CONFIG_MODE_EFFECTIVE" = "manage" ]
      }

      provider_selected() {
        local provider="$1"
        printf '%s' "$MODEL_PROVIDERS_ENABLED_JSON" | jq -e --arg provider "$provider" 'index($provider) != null' >/dev/null 2>&1
      }

      model_provider_from_ref() {
        local model_ref="$1"
        local raw_provider
        raw_provider="$${model_ref%%/*}"
        case "$raw_provider" in
          openai-codex)
            echo "openai"
            ;;
          *)
            echo "$raw_provider"
            ;;
        esac
      }

      model_route_has_credentials() {
        local route="$1"
        case "$route" in
          anthropic)
            has_env_key ANTHROPIC_API_KEY || has_env_key ANTHROPIC_AUTH_KEY
            ;;
          openai)
            has_env_key OPENAI_API_KEY
            ;;
          openai-codex)
            [ -s /opt/agent-stack/codex/auth.json ]
            ;;
          google)
            has_env_key GEMINI_API_KEY
            ;;
          groq)
            has_env_key GROQ_API_KEY
            ;;
          *)
            return 1
            ;;
        esac
      }

      model_exists() {
        local model_ref="$1"
        printf '%s\n' "$MODEL_CATALOG" | grep -Fxq "$model_ref"
      }

      model_is_usable() {
        local model_ref="$1"
        local provider
        local route
        provider=$(model_provider_from_ref "$model_ref")
        route="$${model_ref%%/*}"

        if ! provider_selected "$provider"; then
          echo "[models] WARNING: Skipping $model_ref because provider '$provider' was not selected."
          return 1
        fi
        if ! model_route_has_credentials "$route"; then
          echo "[models] WARNING: Skipping $model_ref because route '$route' credentials are missing."
          return 1
        fi
        if ! model_exists "$model_ref"; then
          echo "[models] WARNING: Skipping $model_ref because it is unavailable in the model catalog."
          return 1
        fi
        return 0
      }

      ensure_plugin_enabled() {
        local plugin="$1"
        local install_log="/tmp/openclaw-plugin-install-$plugin.log"
        local enable_log="/tmp/openclaw-plugin-enable-$plugin.log"

        for attempt in $(seq 1 5); do
          if run_openclaw_cli plugins install "$plugin" >"$install_log" 2>&1; then
            break
          fi
          if grep -qi "already installed" "$install_log"; then
            break
          fi
          sleep 3
        done

        for attempt in $(seq 1 10); do
          if run_openclaw_cli plugins enable "$plugin" >"$enable_log" 2>&1; then
            echo "[plugins] $plugin plugin enabled."
            mark_openclaw_restart_needed
            return 0
          fi
          if grep -qi "already enabled" "$enable_log"; then
            echo "[plugins] $plugin plugin already enabled."
            return 0
          fi
          sleep 3
        done

        echo "[plugins] WARNING: Failed to enable plugin $plugin after retries."
        tail -n 5 "$enable_log" || true
        return 1
      }

      configure_telegram_channel() {
        if ! wait_for_openclaw_config; then
          echo "[telegram] WARNING: $OPENCLAW_CONFIG not found; skipped Telegram setup."
          return 1
        fi

        local token
        token=$(env_value TELEGRAM_BOT_TOKEN)
        local tmp_config
        tmp_config=$(mktemp)
        if jq --arg token "$token" --argjson allow_from "$TELEGRAM_ALLOW_FROM_JSON" '.channels = (.channels // {}) | .channels.telegram = ((.channels.telegram // {}) + { enabled: true, botToken: $token, streaming: "off" }) | if (($allow_from | type) == "array" and ($allow_from | length) > 0) then .channels.telegram.allowFrom = $allow_from else . end' "$OPENCLAW_CONFIG" > "$tmp_config"; then
          if ! cmp -s "$tmp_config" "$OPENCLAW_CONFIG"; then
            mv "$tmp_config" "$OPENCLAW_CONFIG"
            chown 1000:1000 "$OPENCLAW_CONFIG" || true
            echo "[telegram] Telegram channel config updated."
            mark_openclaw_restart_needed
          else
            rm -f "$tmp_config"
            echo "[telegram] Telegram channel config already up to date."
          fi
        else
          rm -f "$tmp_config"
          echo "[telegram] WARNING: Failed to update Telegram channel config."
          return 1
        fi
      }

      if [ "$OPENCLAW_ENABLED" = "true" ] && config_customizations_enabled; then
        echo "[config] Applying optional channel and model bootstrap customizations."

        if wait_openclaw_healthy; then
          case "$AGENT_CHANNEL" in
            telegram)
              if has_env_key TELEGRAM_BOT_TOKEN; then
                ensure_plugin_enabled "telegram" || true
                configure_telegram_channel || true
              else
                echo "[plugins] WARNING: agent_channel=telegram but TELEGRAM_BOT_TOKEN is missing; skipping Telegram plugin/config setup."
                if [ "$TELEGRAM_ALLOW_FROM_JSON" != "[]" ]; then
                  echo "[telegram] NOTE: telegram_allow_from was provided but TELEGRAM_BOT_TOKEN is missing; allowlist was not applied."
                fi
              fi
              ;;
            whatsapp)
              ensure_plugin_enabled "whatsapp" || true
              ;;
          esac
        else
          echo "[plugins] WARNING: OpenClaw did not become ready in time; skipping plugin setup."
        fi

        # Anthropic works from ANTHROPIC_API_KEY at runtime. Keep the old setup-token
        # path only as an explicit legacy fallback when a token is provided.
        if provider_selected "anthropic"; then
          if has_env_key ANTHROPIC_AUTH_KEY; then
            echo "[anthropic] Registering legacy Anthropic setup-token..."
            if wait_openclaw_healthy; then
              if run_openclaw_cli onboard --non-interactive \
                  --auth-choice token \
                  --token-provider anthropic \
                  --token "${anthropic_auth_key}" \
                  --token-expires-in 365d; then
                echo "[anthropic] Legacy setup-token registered successfully."
              else
                echo "[anthropic] WARNING: Legacy onboard --non-interactive command failed."
              fi
            else
              echo "[anthropic] WARNING: OpenClaw not healthy; skipped legacy token registration."
            fi
          elif has_env_key ANTHROPIC_API_KEY; then
            echo "[anthropic] Using ANTHROPIC_API_KEY runtime auth."
          else
            echo "[anthropic] WARNING: Provider anthropic selected, but no Anthropic credential is configured."
          fi
        else
          echo "[anthropic] Provider not selected; skipping Anthropic auth bootstrap."
        fi

        echo "[models] Configuring user-selected model defaults and fallbacks..."
        if wait_openclaw_healthy; then
          MODEL_CATALOG=$(run_openclaw_cli models list --all --plain 2>/dev/null || true)
          if model_is_usable "$DEFAULT_MODEL_REF"; then
            if run_openclaw_cli models set "$DEFAULT_MODEL_REF" >/tmp/openclaw-models-set.log 2>&1; then
              echo "[models] Default model set: $DEFAULT_MODEL_REF"
              if run_openclaw_cli models fallbacks clear >/tmp/openclaw-models-fallback-clear.log 2>&1; then
                echo "[models] Cleared existing fallbacks."
              else
                echo "[models] WARNING: Failed to clear existing fallbacks."
                tail -n 5 /tmp/openclaw-models-fallback-clear.log || true
              fi

              while IFS= read -r fallback_model; do
                [ -n "$fallback_model" ] || continue
                if model_is_usable "$fallback_model"; then
                  if run_openclaw_cli models fallbacks add "$fallback_model" >/tmp/openclaw-models-fallback-add.log 2>&1; then
                    echo "[models] Added fallback: $fallback_model"
                  else
                    echo "[models] WARNING: Failed to add fallback: $fallback_model"
                    tail -n 5 /tmp/openclaw-models-fallback-add.log || true
                  fi
                fi
              done < <(printf '%s' "$FALLBACK_MODELS_JSON" | jq -r '.[]')
            else
              echo "[models] WARNING: Failed to set default model: $DEFAULT_MODEL_REF"
              tail -n 5 /tmp/openclaw-models-set.log || true
            fi
          fi
        else
          echo "[models] WARNING: OpenClaw not ready; skipped model configuration."
        fi
      else
        echo "[config] OpenClaw disabled or config mode is '$OPENCLAW_CONFIG_MODE_EFFECTIVE'; skipping optional channel and model customizations."
      fi

      TAILSCALE_DNS=""
%{ if tailscale_enabled }
      # 6. Read Tailscale sidecar status and Serve URL
      echo "[tailscale] Waiting for Tailscale sidecar..."
      TS_CONTAINER_ID=""
      for attempt in $(seq 1 40); do
        TS_CONTAINER_ID=$(docker compose -f /opt/agent-stack/docker-compose.yml ps -q tailscale || true)
        if [ -n "$TS_CONTAINER_ID" ] && docker exec "$TS_CONTAINER_ID" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
          break
        fi
        sleep 3
      done

      if [ -n "$TS_CONTAINER_ID" ]; then
        TAILSCALE_DNS=$(docker exec "$TS_CONTAINER_ID" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -r '.Self.DNSName // empty' || true)
        TAILSCALE_DNS="$${TAILSCALE_DNS%.}"
        if [ -n "$TAILSCALE_DNS" ]; then
          echo "[tailscale] Serve URL: https://$TAILSCALE_DNS"
        else
          echo "[tailscale] Sidecar started. Check logs with: docker compose -f /opt/agent-stack/docker-compose.yml logs tailscale"
        fi
      else
        echo "[tailscale] WARNING: Tailscale sidecar container not detected."
      fi
%{ endif }

      # 7. Refresh OpenClaw gateway token and allowed origins when OpenClaw is enabled.
      if [ "$OPENCLAW_ENABLED" = "true" ]; then
        echo "[openclaw] Refreshing gateway token and gateway.controlUi.allowedOrigins..."
        PROJECT_ORIGIN=""
%{ if tailscale_enabled }
        PROJECT_ORIGIN="https://${project_name}"
%{ endif }
        PUBLIC_OPENCLAW_ORIGIN=""
%{ if caddy_enabled && openclaw_domain != "" }
        PUBLIC_OPENCLAW_ORIGIN="https://${openclaw_domain}"
%{ endif }
        if wait_for_openclaw_config; then
          ORIGINS_JSON=$(jq -nc --arg project_origin "$PROJECT_ORIGIN" --arg tailscale_dns "$TAILSCALE_DNS" --arg public_origin "$PUBLIC_OPENCLAW_ORIGIN" '[
            "http://127.0.0.1:18789",
            "http://localhost:18789",
            (if $project_origin != "" then $project_origin else empty end),
            (if $tailscale_dns != "" then "https://" + $tailscale_dns else empty end),
            (if $public_origin != "" then $public_origin else empty end)
          ] | unique')
          TMP_CONFIG=$(mktemp)
          if jq --argjson origins "$ORIGINS_JSON" --arg gateway_token "${gateway_token}" '.gateway = (.gateway // {}) | .gateway.auth = ((.gateway.auth // {}) + { mode: "token", token: $gateway_token }) | .gateway.controlUi = ((.gateway.controlUi // {}) + { allowedOrigins: $origins })' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"; then
            if ! cmp -s "$TMP_CONFIG" "$OPENCLAW_CONFIG"; then
              mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
              chown 1000:1000 "$OPENCLAW_CONFIG" || true
              echo "[openclaw] Updated gateway.auth.token and gateway.controlUi.allowedOrigins."
              mark_openclaw_restart_needed
            else
              rm -f "$TMP_CONFIG"
              echo "[openclaw] Gateway config already up to date."
            fi
          else
            rm -f "$TMP_CONFIG"
            echo "[openclaw] WARNING: Failed to update gateway config."
          fi
        else
          echo "[openclaw] WARNING: $OPENCLAW_CONFIG not found; skipped gateway config update."
        fi
      else
        echo "[openclaw] OpenClaw is disabled; skipped gateway config update."
      fi

      if [ "$NEEDS_RESTART" = "1" ]; then
        echo "[openclaw] Applying accumulated config changes with one final restart..."
        systemctl restart agent-stack
        wait_openclaw_healthy || echo "[openclaw] WARNING: OpenClaw did not become healthy after final restart."
      fi

      echo "========================================================"
      echo " Bootstrap complete  $(date)"
      echo " Services:  ${enabled_services_json}"
%{ if tailscale_enabled }
%{ if openclaw_enabled }
      echo " OpenClaw:  https://${project_name}  (via Tailscale Serve sidecar)"
%{ endif }
%{ else }
%{ if openclaw_enabled }
      echo " OpenClaw:  ssh -L 18789:127.0.0.1:18789 ${admin_username}@<IP>"
%{ endif }
%{ endif }
%{ if hermes_enabled }
      echo " Hermes:    ssh -L 9119:127.0.0.1:9119 ${admin_username}@<IP>"
%{ endif }
%{ if n8n_enabled }
      echo " n8n:       ssh -L 5678:127.0.0.1:5678 ${admin_username}@<IP>"
%{ endif }
%{ if caddy_enabled }
      echo " Public UI: Caddy is enabled; use the configured service domains."
%{ endif }
      echo " Logs:      journalctl -u agent-stack -f"
      echo "========================================================"

runcmd:
  - /root/install-agent-stack.sh
