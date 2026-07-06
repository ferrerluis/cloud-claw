#!/usr/bin/env bash
set -euo pipefail

app=/opt/agent-stack
compose="$app/docker-compose.yml"

usage() {
  cat <<'EOF'
Usage:
  agent-stack-diagnostics status
  agent-stack-diagnostics health [openclaw|workspace|tailscale|vpn]
  agent-stack-diagnostics logs <openclaw|hermes|n8n|postgres|caddy|workspace|tailscale|vpn|agent-stack> [lines]
  agent-stack-diagnostics inspect <openclaw|hermes|n8n|postgres|caddy|workspace|tailscale|vpn|agent-stack>
  agent-stack-diagnostics restart <openclaw|hermes|n8n|postgres|caddy|workspace|tailscale|vpn|agent-stack>
EOF
}

compose_service() {
  case "$1" in
    openclaw|hermes|n8n|postgres|caddy|workspace) return 0 ;;
    *) return 1 ;;
  esac
}

managed_service() {
  case "$1" in
    openclaw|hermes|n8n|postgres|caddy|workspace|tailscale|vpn|agent-stack) return 0 ;;
    *) return 1 ;;
  esac
}

require_managed_service() {
  local service="$1"
  if ! managed_service "$service"; then
    echo "unsupported service: $service" >&2
    exit 64
  fi
}

lines_arg() {
  local lines="$${1:-120}"
  if ! printf '%s' "$lines" | grep -Eq '^[0-9]{1,4}$'; then
    echo "invalid line count: $lines" >&2
    exit 64
  fi
  printf '%s' "$lines"
}

container_id() {
  local service="$1"
  docker compose -f "$compose" ps -q "$service" 2>/dev/null || true
}

show_container_inspect() {
  local service="$1"
  local cid
  cid="$(container_id "$service")"
  if [ -z "$cid" ]; then
    echo "container not found for service: $service" >&2
    return 0
  fi

  docker inspect --format 'name={{.Name}} image={{.Config.Image}} created={{.Created}} status={{.State.Status}} running={{.State.Running}} restartCount={{.RestartCount}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' "$cid"
  docker inspect --format '{{range .Mounts}}mount={{.Type}}:{{.Source}}->{{.Destination}}:{{.Mode}}{{println}}{{end}}' "$cid"
}

show_status() {
  echo "== systemd =="
  systemctl is-active agent-stack 2>/dev/null || true
  systemctl is-active tailscaled 2>/dev/null || true
  systemctl is-active agent-stack-vpn 2>/dev/null || true
  echo
  echo "== containers =="
  docker compose -f "$compose" ps 2>/dev/null || true
  echo
  echo "== tailscale =="
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status --json 2>/dev/null | jq -r '.Self.Online, .Self.DNSName, (.Self.TailscaleIPs[]? // empty), (.Health[]? // empty)' || tailscale status || true
  else
    echo "tailscale command not installed"
  fi
  echo
  echo "== vpn =="
  if systemctl list-unit-files agent-stack-vpn.service >/dev/null 2>&1; then
    systemctl is-active agent-stack-vpn 2>/dev/null || true
    ip -4 route show default 2>/dev/null || true
    ip -o link show 2>/dev/null | grep -E ': tun[0-9]+@?' || true
    curl -fsS --max-time 8 "${vpn_healthcheck_url}" 2>/dev/null || true
    echo
  else
    echo "agent-stack-vpn service not installed"
  fi
}

show_health() {
  local service="$${1:-openclaw}"
  require_managed_service "$service"
  case "$service" in
    openclaw)
      curl -fsS --max-time 5 http://127.0.0.1:18789/healthz || true
      ;;
    workspace)
      local cid
      cid="$(container_id workspace)"
      [ -n "$cid" ] && docker inspect --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" || true
      ;;
    tailscale)
      if command -v tailscale >/dev/null 2>&1; then
        tailscale status --json 2>/dev/null | jq -r '.Self.Online, .Self.DNSName, (.Health[]? // empty)' || true
      fi
      ;;
    vpn)
      systemctl is-active agent-stack-vpn 2>/dev/null || true
      ip -o link show 2>/dev/null | grep -E ': tun[0-9]+@?' || true
      curl -fsS --max-time 8 "${vpn_healthcheck_url}" 2>/dev/null || true
      echo
      ;;
    *)
      local cid
      cid="$(container_id "$service")"
      [ -n "$cid" ] && docker inspect --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restartCount={{.RestartCount}}' "$cid" || true
      ;;
  esac
}

show_logs() {
  local service="$1"
  local lines
  require_managed_service "$service"
  lines="$(lines_arg "$${2:-120}")"
  case "$service" in
    tailscale)
      journalctl -u tailscaled --no-pager -n "$lines" || true
      ;;
    vpn)
      journalctl -u agent-stack-vpn --no-pager -n "$lines" || true
      ;;
    agent-stack)
      journalctl -u agent-stack --no-pager -n "$lines" || true
      ;;
    *)
      compose_service "$service" || { echo "unsupported compose service: $service" >&2; exit 64; }
      docker compose -f "$compose" logs --tail "$lines" "$service" || true
      ;;
  esac
}

show_inspect() {
  local service="$1"
  require_managed_service "$service"
  case "$service" in
    tailscale)
      systemctl status --no-pager tailscaled || true
      if command -v tailscale >/dev/null 2>&1; then
        tailscale status --json 2>/dev/null || true
      fi
      ;;
    vpn)
      systemctl status --no-pager agent-stack-vpn || true
      ip -4 route show || true
      ip -o addr show || true
      ;;
    agent-stack)
      systemctl status --no-pager agent-stack || true
      ;;
    *)
      compose_service "$service" || { echo "unsupported compose service: $service" >&2; exit 64; }
      show_container_inspect "$service"
      ;;
  esac
}

restart_service() {
  local service="$1"
  require_managed_service "$service"
  case "$service" in
    tailscale)
      systemctl restart tailscaled
      ;;
    vpn)
      systemctl restart agent-stack-vpn
      ;;
    agent-stack)
      systemctl restart agent-stack
      ;;
    *)
      compose_service "$service" || { echo "unsupported compose service: $service" >&2; exit 64; }
      docker compose -f "$compose" restart "$service"
      ;;
  esac
}

cmd="$${1:-status}"
case "$cmd" in
  status)
    show_status
    ;;
  health)
    show_health "$${2:-openclaw}"
    ;;
  logs)
    [ $# -ge 2 ] || { usage >&2; exit 64; }
    show_logs "$2" "$${3:-120}"
    ;;
  inspect)
    [ $# -eq 2 ] || { usage >&2; exit 64; }
    show_inspect "$2"
    ;;
  restart)
    [ $# -eq 2 ] || { usage >&2; exit 64; }
    restart_service "$2"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
