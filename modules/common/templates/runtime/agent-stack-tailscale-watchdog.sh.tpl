#!/usr/bin/env bash
set -euo pipefail

while true; do
  sleep 60
  ts_container="$(docker compose -f /opt/agent-stack/docker-compose.yml ps -q tailscale 2>/dev/null || true)"
  if [ -z "$ts_container" ]; then
    continue
  fi
  online="$(docker exec "$ts_container" tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null | jq -r '.Self.Online // false' || echo false)"
  routes="$(docker exec "$ts_container" tailscale --socket=/tmp/tailscaled.sock serve status 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  if [ "$online" != "true" ] || [ "$routes" = "0" ]; then
    logger -t agent-stack-tailscale-watchdog "restarting tailscale sidecar (online=$online routes=$routes)"
    docker restart "$ts_container" >/dev/null || true
  fi
done
