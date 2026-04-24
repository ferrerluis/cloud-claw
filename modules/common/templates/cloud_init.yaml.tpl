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
            - /opt/openclaw/data/workspace:/home/node/.openclaw/workspace
%{~ if openai_codex_auth_json_base64 != "" ~}
            - /opt/openclaw/codex:/home/node/.codex
%{~ endif ~}
          healthcheck:
            test: ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
            interval: 30s
            timeout: 10s
            retries: ${openclaw_health_retries}
            start_period: ${openclaw_health_start_period_seconds}s
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
      #      - /opt/openclaw/data/workspace:/data
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
      ANTHROPIC_AUTH_KEY=${anthropic_auth_key}
      OPENAI_API_KEY=${openai_api_key}
      GROQ_API_KEY=${groq_api_key}
      GEMINI_API_KEY=${gemini_api_key}
      TELEGRAM_BOT_TOKEN=${telegram_bot_token}
      OPENCLAW_GATEWAY_TOKEN=${gateway_token}
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

  #  Starter workspace templates (seeded create-if-missing by install script)
  - path: /opt/openclaw/templates/SOUL.balanced.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_soul_balanced_md, "\n", "\n      ")}

  - path: /opt/openclaw/templates/SOUL.builder.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_soul_builder_md, "\n", "\n      ")}

  - path: /opt/openclaw/templates/SOUL.researcher.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_soul_researcher_md, "\n", "\n      ")}

  - path: /opt/openclaw/templates/AGENTS.default.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_agents_md, "\n", "\n      ")}

  - path: /opt/openclaw/templates/TOOLS.default.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_tools_md, "\n", "\n      ")}

  - path: /opt/openclaw/templates/USER.default.md
    permissions: "0644"
    owner: root:root
    content: |
      ${replace(starter_user_md, "\n", "\n      ")}


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

%{ if tailscale_enabled }
  #  Tailscale watchdog (auto-heal sidecar route/online regressions) 
  - path: /usr/local/bin/openclaw-tailscale-watchdog
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      TS_CONTAINER="openclaw-tailscale-1"
      if ! docker ps --format '{{.Names}}' | grep -qx "$TS_CONTAINER"; then
        exit 0
      fi

      ONLINE=$(docker exec "$TS_CONTAINER" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -r '.Self.Online // false' || echo false)
      ROUTE_LINES=$(docker exec "$TS_CONTAINER" sh -lc 'cat /proc/net/route | wc -l' 2>/dev/null || echo 0)
      if [ "$ONLINE" != "true" ] || [ "$ROUTE_LINES" -le 1 ]; then
        logger -t openclaw-tailscale-watchdog "restarting $TS_CONTAINER (online=$ONLINE routes=$ROUTE_LINES)"
        docker restart "$TS_CONTAINER" >/dev/null
      fi

  - path: /etc/systemd/system/openclaw-tailscale-watchdog.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=OpenClaw Tailscale watchdog
      After=docker.service

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/openclaw-tailscale-watchdog

  - path: /etc/systemd/system/openclaw-tailscale-watchdog.timer
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Run OpenClaw Tailscale watchdog every minute

      [Timer]
      OnBootSec=45s
      OnUnitActiveSec=60s
      Unit=openclaw-tailscale-watchdog.service

      [Install]
      WantedBy=timers.target
%{ endif }

  #  Volume mount script (provider-specific) 
  - path: /root/mount-openclaw-volume.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec >> /var/log/openclaw-bootstrap.log 2>&1

      mkdir -p /opt/openclaw/data /opt/openclaw/data/workspace /opt/openclaw/tailscale-state

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
      chown -R 1000:1000 /opt/openclaw/data
      echo "[volume] Mount complete."

  #  Main bootstrap script 
  - path: /root/install-openclaw.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/bin/bash
      set -euo pipefail
      exec > >(tee -a /var/log/openclaw-bootstrap.log) 2>&1
      NEEDS_RESTART=0

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

      OPENAI_CODEX_AUTH_JSON_BASE64='${openai_codex_auth_json_base64}'

      sync_openai_codex_auth() {
        if [ -z "$OPENAI_CODEX_AUTH_JSON_BASE64" ]; then
          echo "[openai-codex] No Codex CLI auth import configured."
          return 0
        fi

        echo "[openai-codex] Importing Codex CLI auth into /opt/openclaw/codex/auth.json..."
        install -d -m 700 -o 1000 -g 1000 /opt/openclaw/codex
        printf '%s' "$OPENAI_CODEX_AUTH_JSON_BASE64" | base64 --decode > /opt/openclaw/codex/auth.json
        chown 1000:1000 /opt/openclaw/codex/auth.json
        chmod 600 /opt/openclaw/codex/auth.json
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

      OPENCLAW_CONFIG="/opt/openclaw/data/openclaw.json"
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

        local workspace_dir="/opt/openclaw/data/workspace"
        local soul_source="/opt/openclaw/templates/SOUL.balanced.md"
        case "$STARTER_SOUL_PROFILE" in
          builder)
            soul_source="/opt/openclaw/templates/SOUL.builder.md"
            ;;
          researcher)
            soul_source="/opt/openclaw/templates/SOUL.researcher.md"
            ;;
        esac

        mkdir -p "$workspace_dir"
        chown 1000:1000 "$workspace_dir" || true
        seed_file_if_missing "$soul_source" "$workspace_dir/SOUL.md"
        seed_file_if_missing "/opt/openclaw/templates/AGENTS.default.md" "$workspace_dir/AGENTS.md"
        seed_file_if_missing "/opt/openclaw/templates/TOOLS.default.md" "$workspace_dir/TOOLS.md"
        seed_file_if_missing "/opt/openclaw/templates/USER.default.md" "$workspace_dir/USER.md"
      }

      # 5. Start OpenClaw
      echo "[openclaw] Enabling and starting OpenClaw service..."
      systemctl daemon-reload
      systemctl enable openclaw
%{ if tailscale_enabled }
      systemctl enable --now openclaw-tailscale-watchdog.timer
%{ endif }
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
          timeout "$${OPENCLAW_CLI_TIMEOUT_SECONDS:-30}" docker exec openclaw-openclaw-1 openclaw "$@"
        else
          docker exec openclaw-openclaw-1 openclaw "$@"
        fi
      }

      OPENCLAW_ENV_FILE="/opt/openclaw/.env"
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
      if wait_openclaw_healthy; then
        seed_starter_workspace_files
      else
        echo "[starter] WARNING: OpenClaw did not become healthy; skipping starter file seed to avoid clobbering first-run files."
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
            [ -s /opt/openclaw/codex/auth.json ]
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

      if config_customizations_enabled; then
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
              if docker exec openclaw-openclaw-1 openclaw onboard --non-interactive \
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
        echo "[config] Config mode is '$OPENCLAW_CONFIG_MODE_EFFECTIVE'; skipping optional channel and model customizations."
      fi

      TAILSCALE_DNS=""
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
        if [ -n "$TAILSCALE_DNS" ]; then
          echo "[tailscale] Serve URL: https://$TAILSCALE_DNS"
        else
          echo "[tailscale] Sidecar started. Check logs with: docker compose -f /opt/openclaw/docker-compose.yml logs tailscale"
        fi
      else
        echo "[tailscale] WARNING: Tailscale sidecar container not detected."
      fi
%{ endif }

      # 7. Always refresh gateway token and allowed origins.
      echo "[openclaw] Refreshing gateway token and gateway.controlUi.allowedOrigins..."
      PROJECT_ORIGIN=""
%{ if tailscale_enabled }
      PROJECT_ORIGIN="https://${project_name}"
%{ endif }
      if wait_for_openclaw_config; then
        ORIGINS_JSON=$(jq -nc --arg project_origin "$PROJECT_ORIGIN" --arg tailscale_dns "$TAILSCALE_DNS" '[
          "http://127.0.0.1:18789",
          "http://localhost:18789",
          (if $project_origin != "" then $project_origin else empty end),
          (if $tailscale_dns != "" then "https://" + $tailscale_dns else empty end)
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

      if [ "$NEEDS_RESTART" = "1" ]; then
        echo "[openclaw] Applying accumulated config changes with one final restart..."
        systemctl restart openclaw
        wait_openclaw_healthy || echo "[openclaw] WARNING: OpenClaw did not become healthy after final restart."
      fi

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
