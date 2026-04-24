#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SSH_WRAPPER="${ROOT_DIR}/bin/cloud-claw-ssh"
LOG_LINES=120

usage() {
  cat <<'EOF'
Usage: skills/claw-doctor/scripts/check_remote_health.sh [--ssh-wrapper <path>] [--log-lines <count>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-wrapper)
      SSH_WRAPPER="${2:-}"
      shift 2
      ;;
    --log-lines)
      LOG_LINES="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "$SSH_WRAPPER" ]]; then
  echo "error: SSH wrapper not found or not executable: $SSH_WRAPPER" >&2
  exit 1
fi

section() {
  printf '\n== %s ==\n' "$1"
}

run_remote() {
  "$SSH_WRAPPER" -- sh -lc "$1"
}

section "Runtime containers"
run_remote "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true"

APP_CONTAINER="$(run_remote "sudo docker ps --format '{{.Names}}' | grep -E '(^|-)openclaw($|-)' | grep -v tailscale | head -n 1" 2>/dev/null || true)"
TS_CONTAINER="$(run_remote "sudo docker ps --format '{{.Names}}' | grep -E 'tailscale' | head -n 1" 2>/dev/null || true)"

section "systemd"
run_remote "sudo systemctl status --no-pager openclaw || true"

section "Bootstrap log"
run_remote "sudo tail -n ${LOG_LINES} /var/log/openclaw-bootstrap.log || true"

section "Gateway health"
run_remote "curl -sv --max-time 5 http://127.0.0.1:18789/healthz 2>&1 | tail -n 40 || true"

if [[ -n "$APP_CONTAINER" ]]; then
  section "App inspect"
  run_remote "sudo docker inspect --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restartCount={{.RestartCount}} started={{.State.StartedAt}}' ${APP_CONTAINER} || true"

  section "App health"
  run_remote "sudo docker exec ${APP_CONTAINER} openclaw health --json || true"

  section "App logs"
  run_remote "sudo docker logs --since 20m ${APP_CONTAINER} | tail -n 200 || true"
else
  section "App container"
  echo "No OpenClaw app container detected."
fi

if [[ -n "$TS_CONTAINER" ]]; then
  section "Tailscale status"
  run_remote "sudo docker exec ${TS_CONTAINER} tailscale --socket=/tmp/tailscaled.sock status --json | jq -r '.Self.Online, .Self.DNSName, (.Health[]? // empty)' || true"

  section "Tailscale serve"
  run_remote "sudo docker exec ${TS_CONTAINER} tailscale --socket=/tmp/tailscaled.sock serve status || true"

  section "Sidecar to app"
  run_remote "sudo docker exec ${TS_CONTAINER} sh -lc 'wget -S -O /dev/null -T 5 http://127.0.0.1:18789 2>&1 | sed -n \"1,40p\"' || true"
else
  section "Tailscale container"
  echo "No Tailscale sidecar container detected."
fi
