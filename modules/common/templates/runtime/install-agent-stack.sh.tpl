#!/usr/bin/env bash
set -euo pipefail

staging="$1"
checksum="$2"
app=/opt/agent-stack
previous="$app/.previous-runtime"
log=/var/log/openclaw-bootstrap.log
NEEDS_RESTART=0

exec > >(tee -a "$log") 2>&1

fail() {
  echo "[runtime] ERROR: $*" >&2
  exit 1
}

require_file() {
  [ -f "$staging/$1" ] || fail "missing staged file: $1"
}

env_file_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^$key=//p" "$file" | tail -n 1 || true
}

require_file docker-compose.yml
require_file .env
require_file mount-agent-stack-volume.sh
require_file agent-stack-migrate-layout
require_file agent-stack.service
require_file openclaw.service
require_file enabled-services.json

echo "[runtime] applying AgentStack runtime checksum=$checksum"

if ! command -v docker >/dev/null 2>&1; then
  echo "[docker] Installing Docker..."
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
usermod -aG docker "${admin_username}" || true

install -d -m 0755 "$app" "$app/templates" "$app/tailscale-state" "$app/data"
install -m 0755 "$staging/mount-agent-stack-volume.sh" /root/mount-agent-stack-volume.sh
/root/mount-agent-stack-volume.sh
install -m 0755 "$staging/agent-stack-migrate-layout" /usr/local/bin/agent-stack-migrate-layout
/usr/local/bin/agent-stack-migrate-layout

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

configure_caddyfile() {
  if ! grep -q '^CADDY_ENABLED=true$' "$staging/.env"; then
    echo "[caddy] Skipped (public_domain_enabled=false)."
    rm -f "$staging/Caddyfile"
    return 0
  fi

  require_file Caddyfile.template
  echo "[caddy] Rendering Caddyfile with hashed basic-auth password..."
  local ui_password
  ui_password="$(env_file_value "$staging/.env" UI_AUTH_PASSWORD)"
  local hash
  hash="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$ui_password")"
  sed "s|__UI_AUTH_HASH__|$hash|g" "$staging/Caddyfile.template" > "$staging/Caddyfile"
  chmod 0600 "$staging/Caddyfile"
}

sync_openai_codex_auth() {
  if [ ! -s "$staging/openai_codex_auth_json_base64" ]; then
    echo "[openai-codex] No Codex CLI auth import configured."
    return 0
  fi

  echo "[openai-codex] Importing Codex CLI auth into $app/codex/auth.json..."
  install -d -m 0700 -o 1000 -g 1000 "$app/codex"
  base64 --decode "$staging/openai_codex_auth_json_base64" > "$app/codex/auth.json"
  chown 1000:1000 "$app/codex/auth.json"
  chmod 0600 "$app/codex/auth.json"
}

configure_caddyfile
configure_swap
docker compose --env-file "$staging/.env" -f "$staging/docker-compose.yml" config >/dev/null

rm -rf "$previous"
install -d -m 0700 "$previous"
for path in docker-compose.yml .env Caddyfile tailscale-bootstrap.sh; do
  [ -e "$app/$path" ] && cp -a "$app/$path" "$previous/" || true
done

install -m 0644 "$staging/docker-compose.yml" "$app/docker-compose.yml"
install -m 0600 "$staging/.env" "$app/.env"
if [ -f "$staging/Caddyfile" ]; then
  install -m 0600 "$staging/Caddyfile" "$app/Caddyfile"
else
  rm -f "$app/Caddyfile"
fi
if [ -f "$staging/tailscale-bootstrap.sh" ]; then
  install -m 0700 "$staging/tailscale-bootstrap.sh" "$app/tailscale-bootstrap.sh"
fi
if [ -d "$staging/templates" ]; then
  rm -rf "$app/templates"
  install -d -m 0755 "$app/templates"
  cp -a "$staging/templates/." "$app/templates/"
  chmod -R u=rwX,go=rX "$app/templates"
fi
sync_openai_codex_auth

install -m 0644 "$staging/agent-stack.service" /etc/systemd/system/agent-stack.service
install -m 0644 "$staging/openclaw.service" /etc/systemd/system/openclaw.service
if [ -f "$staging/agent-stack-tailscale-watchdog" ]; then
  install -m 0755 "$staging/agent-stack-tailscale-watchdog" /usr/local/bin/agent-stack-tailscale-watchdog
  install -m 0644 "$staging/agent-stack-tailscale-watchdog.service" /etc/systemd/system/agent-stack-tailscale-watchdog.service
  install -m 0644 "$staging/agent-stack-tailscale-watchdog.timer" /etc/systemd/system/agent-stack-tailscale-watchdog.timer
fi

systemctl daemon-reload
systemctl enable agent-stack openclaw
if grep -q '^TAILSCALE_AUTH_KEY=' "$app/.env"; then
  systemctl enable --now agent-stack-tailscale-watchdog.timer || true
else
  systemctl disable --now agent-stack-tailscale-watchdog.timer 2>/dev/null || true
fi

if ! systemctl restart agent-stack; then
  echo "[runtime] restart failed; restoring previous runtime files" >&2
  for path in docker-compose.yml .env Caddyfile tailscale-bootstrap.sh; do
    if [ -e "$previous/$path" ]; then
      cp -a "$previous/$path" "$app/$path"
    else
      rm -f "$app/$path"
    fi
  done
  systemctl restart agent-stack || true
  fail "agent-stack restart failed"
fi
systemctl start openclaw || true

OPENCLAW_CONFIG="$app/data/openclaw/openclaw.json"
OPENCLAW_ENABLED="${openclaw_enabled}"
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

wait_openclaw_healthy() {
  if [ "$OPENCLAW_ENABLED" != "true" ]; then
    return 1
  fi
  for attempt in $(seq 1 60); do
    local container_id
    container_id="$(docker compose -f "$app/docker-compose.yml" ps -q openclaw 2>/dev/null || true)"
    if [ -n "$container_id" ]; then
      local health_status
      health_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      if [ "$health_status" = "healthy" ] || [ "$health_status" = "running" ]; then
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

run_openclaw_cli() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$${OPENCLAW_CLI_TIMEOUT_SECONDS:-30}" docker compose -f "$app/docker-compose.yml" exec -T openclaw openclaw "$@"
  else
    docker compose -f "$app/docker-compose.yml" exec -T openclaw openclaw "$@"
  fi
}

env_value() {
  env_file_value "$app/.env" "$1"
}

has_env_key() {
  local key="$1"
  local value
  value="$(env_value "$key")"
  [ -n "$value" ]
}

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

  local workspace_dir="$app/data/openclaw/workspace"
  local soul_source="$app/templates/SOUL.${starter_soul_profile}.md"
  if [ ! -f "$soul_source" ]; then
    soul_source="$app/templates/SOUL.balanced.md"
  fi

  mkdir -p "$workspace_dir"
  chown 1000:1000 "$workspace_dir" || true
  seed_file_if_missing "$soul_source" "$workspace_dir/SOUL.md"
  seed_file_if_missing "$app/templates/AGENTS.default.md" "$workspace_dir/AGENTS.md"
  seed_file_if_missing "$app/templates/TOOLS.default.md" "$workspace_dir/TOOLS.md"
  seed_file_if_missing "$app/templates/USER.default.md" "$workspace_dir/USER.md"
}

if [ "$OPENCLAW_ENABLED" = "true" ]; then
  if wait_openclaw_healthy; then
    seed_starter_workspace_files
  else
    echo "[starter] WARNING: OpenClaw did not become healthy; skipping starter file seed."
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
      [ -s "$app/codex/auth.json" ]
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
  provider="$(model_provider_from_ref "$model_ref")"
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
  token="$(env_value TELEGRAM_BOT_TOKEN)"
  local tmp_config
  tmp_config="$(mktemp)"
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

configure_openclaw_channels_and_models() {
  if [ "$OPENCLAW_ENABLED" != "true" ] || ! config_customizations_enabled; then
    echo "[config] OpenClaw disabled or config mode is '$OPENCLAW_CONFIG_MODE_EFFECTIVE'; skipping optional channel and model customizations."
    return 0
  fi

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

  if provider_selected "anthropic"; then
    if has_env_key ANTHROPIC_AUTH_KEY; then
      echo "[anthropic] Registering legacy Anthropic setup-token..."
      if wait_openclaw_healthy; then
        local anthropic_auth_key
        anthropic_auth_key="$(env_value ANTHROPIC_AUTH_KEY)"
        if run_openclaw_cli onboard --non-interactive \
            --auth-choice token \
            --token-provider anthropic \
            --token "$anthropic_auth_key" \
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
    MODEL_CATALOG="$(run_openclaw_cli models list --all --plain 2>/dev/null || true)"
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
}

read_tailscale_dns() {
  local tailscale_dns=""
  if ! grep -q '^TAILSCALE_AUTH_KEY=' "$app/.env"; then
    printf '%s' "$tailscale_dns"
    return 0
  fi

  echo "[tailscale] Waiting for Tailscale sidecar..." >&2
  local ts_container_id=""
  for attempt in $(seq 1 40); do
    ts_container_id="$(docker compose -f "$app/docker-compose.yml" ps -q tailscale 2>/dev/null || true)"
    if [ -n "$ts_container_id" ] && docker exec "$ts_container_id" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
      break
    fi
    sleep 3
  done

  if [ -n "$ts_container_id" ]; then
    tailscale_dns="$(docker exec "$ts_container_id" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -r '.Self.DNSName // empty' || true)"
    tailscale_dns="$${tailscale_dns%.}"
    if [ -n "$tailscale_dns" ]; then
      echo "[tailscale] Serve URL: https://$tailscale_dns" >&2
    else
      echo "[tailscale] Sidecar started. Check logs with: docker compose -f $app/docker-compose.yml logs tailscale" >&2
    fi
  else
    echo "[tailscale] WARNING: Tailscale sidecar container not detected." >&2
  fi

  printf '%s' "$tailscale_dns"
}

refresh_openclaw_gateway_config() {
  if [ "$OPENCLAW_ENABLED" != "true" ]; then
    echo "[openclaw] OpenClaw is disabled; skipped gateway config update."
    return 0
  fi

  echo "[openclaw] Refreshing gateway token and gateway.controlUi.allowedOrigins..."
  local tailscale_dns="$1"
  local project_origin=""
  if grep -q '^TAILSCALE_AUTH_KEY=' "$app/.env"; then
    project_origin="https://${project_name}"
  fi
  local public_openclaw_origin=""
  if [ "${openclaw_domain}" != "" ]; then
    public_openclaw_origin="https://${openclaw_domain}"
  fi

  if ! wait_for_openclaw_config; then
    echo "[openclaw] WARNING: $OPENCLAW_CONFIG not found; skipped gateway config update."
    return 0
  fi

  local origins_json
  origins_json="$(jq -nc --arg project_origin "$project_origin" --arg tailscale_dns "$tailscale_dns" --arg public_origin "$public_openclaw_origin" '[
    "http://127.0.0.1:18789",
    "http://localhost:18789",
    (if $project_origin != "" then $project_origin else empty end),
    (if $tailscale_dns != "" then "https://" + $tailscale_dns else empty end),
    (if $public_origin != "" then $public_origin else empty end)
  ] | unique')"
  local gateway_token
  gateway_token="$(env_value OPENCLAW_GATEWAY_TOKEN)"
  local tmp_config
  tmp_config="$(mktemp)"
  if jq --argjson origins "$origins_json" --arg gateway_token "$gateway_token" '.gateway = (.gateway // {}) | .gateway.auth = ((.gateway.auth // {}) + { mode: "token", token: $gateway_token }) | .gateway.controlUi = ((.gateway.controlUi // {}) + { allowedOrigins: $origins })' "$OPENCLAW_CONFIG" > "$tmp_config"; then
    if ! cmp -s "$tmp_config" "$OPENCLAW_CONFIG"; then
      mv "$tmp_config" "$OPENCLAW_CONFIG"
      chown 1000:1000 "$OPENCLAW_CONFIG" || true
      echo "[openclaw] Updated gateway.auth.token and gateway.controlUi.allowedOrigins."
      mark_openclaw_restart_needed
    else
      rm -f "$tmp_config"
      echo "[openclaw] Gateway config already up to date."
    fi
  else
    rm -f "$tmp_config"
    echo "[openclaw] WARNING: Failed to update gateway config."
  fi
}

restart_agent_stack_for_config() {
  local restart_status=0
  systemctl restart agent-stack || restart_status=$?
  if [ "$restart_status" != "0" ]; then
    echo "[openclaw] WARNING: systemctl restart agent-stack exited $restart_status; waiting for service recovery before deciding failure."
  fi

  for attempt in $(seq 1 36); do
    if systemctl is-active --quiet agent-stack; then
      if [ "$OPENCLAW_ENABLED" != "true" ] || wait_openclaw_healthy; then
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

openclaw_config_backup=""
if [ -f "$OPENCLAW_CONFIG" ]; then
  openclaw_config_backup="$(mktemp)"
  cp -a "$OPENCLAW_CONFIG" "$openclaw_config_backup"
fi

configure_openclaw_channels_and_models
TAILSCALE_DNS="$(read_tailscale_dns)"
refresh_openclaw_gateway_config "$TAILSCALE_DNS"

if [ "$NEEDS_RESTART" = "1" ]; then
  echo "[openclaw] Applying accumulated config changes with one final restart..."
  if ! restart_agent_stack_for_config; then
    if [ -n "$openclaw_config_backup" ] && [ -f "$openclaw_config_backup" ]; then
      cp -a "$openclaw_config_backup" "$OPENCLAW_CONFIG"
      chown 1000:1000 "$OPENCLAW_CONFIG" || true
      systemctl restart agent-stack || true
    fi
    fail "agent-stack restart failed after OpenClaw config changes"
  fi
fi
rm -f "$openclaw_config_backup"

jq -n \
  --arg checksum "$checksum" \
  --arg applied_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile services "$staging/enabled-services.json" \
  '{status:"success", checksum:$checksum, applied_at:$applied_at, services:($services[0] // [])}' \
  > "$app/.last-apply.json"
chmod 0600 "$app/.last-apply.json"
rm -rf "$staging"

echo "========================================================"
echo " AgentStack runtime apply complete  $(date)"
echo " Services: ${enabled_services_json}"
if [ "$OPENCLAW_ENABLED" = "true" ]; then
  if [ -n "${project_name}" ] && grep -q '^TAILSCALE_AUTH_KEY=' "$app/.env"; then
    echo " OpenClaw: https://${project_name} (via Tailscale Serve sidecar)"
  else
    echo " OpenClaw: ssh -L 18789:127.0.0.1:18789 ${admin_username}@<IP>"
  fi
fi
echo " Logs: journalctl -u agent-stack -f"
echo "========================================================"
