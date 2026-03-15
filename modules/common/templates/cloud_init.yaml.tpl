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

      # 5. Install/enable required plugins for channel + ACP workflows
      echo "[plugins] Installing/enabling plugins (acpx, whatsapp, telegram)..."
      PLUGINS_RESTART_NEEDED=0
      if wait_openclaw_healthy; then
        ACPX_INSTALL_LOG="/tmp/openclaw-plugin-install-acpx.log"
        ACPX_INSTALL_OK=0
        for attempt in $(seq 1 5); do
          if run_openclaw_cli plugins install acpx >"$ACPX_INSTALL_LOG" 2>&1; then
            echo "[plugins] acpx plugin installed."
            ACPX_INSTALL_OK=1
            PLUGINS_RESTART_NEEDED=1
            break
          fi
          if grep -qi "already installed" "$ACPX_INSTALL_LOG"; then
            echo "[plugins] acpx plugin already installed."
            ACPX_INSTALL_OK=1
            break
          fi
          sleep 3
        done
        if [ "$ACPX_INSTALL_OK" != "1" ]; then
          echo "[plugins] WARNING: Failed to install acpx plugin after retries."
          tail -n 5 "$ACPX_INSTALL_LOG" || true
        fi

        for plugin in acpx whatsapp telegram; do
          PLUGIN_ENABLE_LOG="/tmp/openclaw-plugin-enable-$plugin.log"
          ENABLE_OK=0
          for attempt in $(seq 1 10); do
            if run_openclaw_cli plugins enable "$plugin" >"$PLUGIN_ENABLE_LOG" 2>&1; then
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
          echo "[plugins] Plugin changes detected; scheduling a deferred OpenClaw restart."
          mark_openclaw_restart_needed
        fi
      else
        echo "[plugins] WARNING: OpenClaw did not become ready in time; skipping plugin enable."
      fi

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

      # 6. Preconfigure Telegram bot token (optional)
      TELEGRAM_ALLOW_FROM_JSON='${telegram_allow_from_json}'
      if has_env_key TELEGRAM_BOT_TOKEN; then
        echo "[telegram] Configuring channels.telegram.botToken..."
        OPENCLAW_CONFIG="/opt/openclaw/data/openclaw.json"
        TELEGRAM_TOKEN=$(env_value TELEGRAM_BOT_TOKEN)
        if [ -f "$OPENCLAW_CONFIG" ]; then
          TMP_CONFIG=$(mktemp)
          if jq --arg token "$TELEGRAM_TOKEN" --argjson allow_from "$TELEGRAM_ALLOW_FROM_JSON" '.channels = (.channels // {}) | .channels.telegram = ((.channels.telegram // {}) + { enabled: true, botToken: $token, streaming: "off" }) | if (($allow_from | type) == "array" and ($allow_from | length) > 0) then .channels.telegram.allowFrom = $allow_from else . end' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"; then
            if ! cmp -s "$TMP_CONFIG" "$OPENCLAW_CONFIG"; then
              mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
              chown 1000:1000 "$OPENCLAW_CONFIG" || true
              echo "[telegram] Telegram channel config updated."
              mark_openclaw_restart_needed
            else
              rm -f "$TMP_CONFIG"
              echo "[telegram] Telegram channel config already up to date."
            fi
          else
            rm -f "$TMP_CONFIG"
            echo "[telegram] WARNING: Failed to update Telegram channel config."
          fi
        else
          echo "[telegram] WARNING: $OPENCLAW_CONFIG not found; skipped Telegram setup."
        fi
      else
        echo "[telegram] No TELEGRAM_BOT_TOKEN provided; skipping Telegram pre-setup."
        if [ "$TELEGRAM_ALLOW_FROM_JSON" != "[]" ]; then
          echo "[telegram] NOTE: telegram_allow_from was provided but TELEGRAM_BOT_TOKEN is missing; allowlist was not applied."
        fi
      fi

      # 7. Configure context pruning defaults to prevent oversized sessions
      echo "[pruning] Configuring agents.defaults.contextPruning..."
      OPENCLAW_CONFIG="/opt/openclaw/data/openclaw.json"
      if [ -f "$OPENCLAW_CONFIG" ]; then
        TMP_CONFIG=$(mktemp)
        if jq '.agents = (.agents // {}) | .agents.defaults = ((.agents.defaults // {}) + { contextPruning: { mode: "cache-ttl", ttl: "5m", keepLastAssistants: 3, softTrimRatio: 0.3, hardClearRatio: 0.5, minPrunableToolChars: 50000, softTrim: { maxChars: 4000, headChars: 1500, tailChars: 1500 }, hardClear: { enabled: true, placeholder: "[Old tool result content cleared]" } } })' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"; then
          if ! cmp -s "$TMP_CONFIG" "$OPENCLAW_CONFIG"; then
            mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
            chown 1000:1000 "$OPENCLAW_CONFIG" || true
            echo "[pruning] Context pruning config updated."
            mark_openclaw_restart_needed
          else
            rm -f "$TMP_CONFIG"
            echo "[pruning] Context pruning config already up to date."
          fi
        else
          rm -f "$TMP_CONFIG"
          echo "[pruning] WARNING: Failed to update context pruning config."
        fi
      else
        echo "[pruning] WARNING: $OPENCLAW_CONFIG not found; skipped context pruning setup."
      fi

      # 8. Configure multi-agent + ACP defaults
      echo "[agents] Configuring session visibility, agent-to-agent policy, and ACP defaults..."
      OPENCLAW_CONFIG="/opt/openclaw/data/openclaw.json"
      if [ -f "$OPENCLAW_CONFIG" ]; then
        TMP_CONFIG=$(mktemp)
        if jq '
          def upsert_agent($agent):
            .agents.list = (
              (.agents.list // []) as $list
              | if ($list | map(.id) | index($agent.id)) != null
                then ($list | map(if .id == $agent.id then (. * $agent) else . end))
                else ($list + [$agent])
                end
            );

          .tools = (.tools // {})
          | .tools.sessions = ((.tools.sessions // {}) + { visibility: "tree" })
          | .tools.agentToAgent = ((.tools.agentToAgent // {}) + { enabled: true, allow: ["researcher", "coder"] })
          | .agents = (.agents // {})
          | .agents.defaults = (.agents.defaults // {})
          | .agents.defaults.sandbox = ((.agents.defaults.sandbox // {}) + { sessionToolsVisibility: "spawned" })
          | .acp = (.acp // {})
          | .acp.enabled = true
          | .acp.dispatch = ((.acp.dispatch // {}) + { enabled: true })
          | .acp.backend = "acpx"
          | .acp.defaultAgent = "codex"
          | .acp.allowedAgents = ["codex"]
          | .plugins = (.plugins // {})
          | .plugins.entries = (.plugins.entries // {})
          | .plugins.entries.acpx = ((.plugins.entries.acpx // {}) + { enabled: true })
          | .plugins.entries.acpx.config = ((.plugins.entries.acpx.config // {}) + { permissionMode: "approve-all", nonInteractivePermissions: "fail" })
          | upsert_agent({
              id: "main",
              subagents: { allowAgents: ["researcher", "coder"] }
            })
          | upsert_agent({
              id: "researcher"
            })
          | upsert_agent({
              id: "coder",
              runtime: {
                type: "acp",
                acp: { agent: "codex", backend: "acpx", mode: "persistent" }
              }
            })
        ' "$OPENCLAW_CONFIG" > "$TMP_CONFIG"; then
          if ! cmp -s "$TMP_CONFIG" "$OPENCLAW_CONFIG"; then
            mv "$TMP_CONFIG" "$OPENCLAW_CONFIG"
            chown 1000:1000 "$OPENCLAW_CONFIG" || true
            echo "[agents] Multi-agent + ACP defaults updated."
            mark_openclaw_restart_needed
          else
            rm -f "$TMP_CONFIG"
            echo "[agents] Multi-agent + ACP defaults already up to date."
          fi
        else
          rm -f "$TMP_CONFIG"
          echo "[agents] WARNING: Failed to update multi-agent + ACP defaults."
        fi
      else
        echo "[agents] WARNING: $OPENCLAW_CONFIG not found; skipped multi-agent + ACP setup."
      fi

      # 9. Configure model defaults/fallbacks from available API keys
      echo "[models] Configuring model defaults and fallbacks..."
      OPENCLAW_ENV_FILE="/opt/openclaw/.env"
      model_exists() {
        local model_ref="$1"
        printf '%s\n' "$MODEL_CATALOG" | grep -Fxq "$model_ref"
      }
      add_fallback_model() {
        local model_ref="$1"
        if run_openclaw_cli models fallbacks add "$model_ref" >/tmp/openclaw-models-fallback-add.log 2>&1; then
          echo "[models] Added fallback: $model_ref"
        else
          echo "[models] WARNING: Failed to add fallback: $model_ref"
          tail -n 5 /tmp/openclaw-models-fallback-add.log || true
        fi
      }

      if wait_openclaw_healthy; then
        MODEL_CATALOG=$(run_openclaw_cli models list --all --plain 2>/dev/null || true)
        DEFAULT_MODEL="google/gemini-3-flash"
        GEMINI_PRO_MODEL="google/gemini-3-pro-preview"
        HAIKU_MODEL="anthropic/claude-haiku-4-5"
        SONNET_MODEL="anthropic/claude-sonnet-4-6"
        OPUS_MODEL="anthropic/claude-opus-4-6"

        if has_env_key GEMINI_API_KEY && model_exists "$DEFAULT_MODEL"; then
          if run_openclaw_cli models set "$DEFAULT_MODEL" >/tmp/openclaw-models-set.log 2>&1; then
            echo "[models] Default model set: $DEFAULT_MODEL"
            if run_openclaw_cli models fallbacks clear >/tmp/openclaw-models-fallback-clear.log 2>&1; then
              echo "[models] Cleared existing fallbacks."
            else
              echo "[models] WARNING: Failed to clear existing fallbacks."
              tail -n 5 /tmp/openclaw-models-fallback-clear.log || true
            fi

            # Fallback priority:
            # 1) Gemini 3 Pro  2) Claude Haiku 4.5  3) Claude Sonnet 4.6  4) Claude Opus 4.6
            if has_env_key GEMINI_API_KEY && model_exists "$GEMINI_PRO_MODEL"; then
              add_fallback_model "$GEMINI_PRO_MODEL"
            fi
            if has_env_key ANTHROPIC_API_KEY && model_exists "$HAIKU_MODEL"; then
              add_fallback_model "$HAIKU_MODEL"
            fi
            if has_env_key ANTHROPIC_API_KEY && model_exists "$SONNET_MODEL"; then
              add_fallback_model "$SONNET_MODEL"
            fi
            if has_env_key ANTHROPIC_API_KEY && model_exists "$OPUS_MODEL"; then
              add_fallback_model "$OPUS_MODEL"
            fi
          else
            echo "[models] WARNING: Failed to set default model: $DEFAULT_MODEL"
            tail -n 5 /tmp/openclaw-models-set.log || true
          fi
        else
          echo "[models] Skipped: GEMINI_API_KEY missing or $DEFAULT_MODEL unavailable in catalog."
        fi
      else
        echo "[models] WARNING: OpenClaw not ready; skipped model configuration."
      fi

%{ if tailscale_enabled }
      # 10. Read Tailscale sidecar status and Serve URL
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
            mark_openclaw_restart_needed
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
