#!/usr/bin/env bash
set -euo pipefail

mode="$${1:-enable}"
staging="$${2:-}"

VPN_ENABLED="${vpn_enabled}"
VPN_PROVIDER="${vpn_provider}"
OPENVPN_CONFIG_URL="${vpn_openvpn_config_url}"
VPN_BYPASS_CIDRS_JSON='${vpn_bypass_cidrs_json}'
VPN_DISABLE_IPV6="${vpn_disable_ipv6}"
VPN_HEALTHCHECK_URL="${vpn_healthcheck_url}"

config_dir=/etc/agent-stack-vpn
service_path=/etc/systemd/system/agent-stack-vpn.service
routes_path=/usr/local/bin/agent-stack-vpn-routes

log() {
  echo "[vpn] $*"
}

fail() {
  echo "[vpn] ERROR: $*" >&2
  exit 1
}

disable_vpn() {
  log "Disabling host VPN service."
  systemctl disable --now agent-stack-vpn.service 2>/dev/null || true
  rm -f "$service_path" "$routes_path"
  rm -rf "$config_dir"
  if [ -f /etc/sysctl.d/99-agent-stack-vpn-ipv6.conf ]; then
    rm -f /etc/sysctl.d/99-agent-stack-vpn-ipv6.conf
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload || true
}

install_openvpn() {
  if command -v openvpn >/dev/null 2>&1; then
    return 0
  fi

  log "Installing OpenVPN package."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y openvpn
}

write_route_helper() {
  install -d -m 0755 "$config_dir"
  printf '%s\n' "$VPN_BYPASS_CIDRS_JSON" > "$config_dir/bypass-cidrs.json"
  chmod 0644 "$config_dir/bypass-cidrs.json"

  cat > "$routes_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

config_dir=/etc/agent-stack-vpn
cidrs_file="$config_dir/bypass-cidrs.json"

find_original_default_route() {
  ip -4 route show default 0.0.0.0/0 | head -n 1
}

add_route() {
  local cidr="$1"
  local gateway="$2"
  local dev="$3"
  [ -n "$cidr" ] || return 0
  ip -4 route replace "$cidr" via "$gateway" dev "$dev"
}

setup_routes() {
  local default_route gateway dev
  default_route="$(find_original_default_route || true)"
  [ -n "$default_route" ] || { echo "no IPv4 default route found" >&2; exit 1; }

  gateway="$(printf '%s\n' "$default_route" | awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}')"
  dev="$(printf '%s\n' "$default_route" | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
  [ -n "$gateway" ] || { echo "default route has no gateway: $default_route" >&2; exit 1; }
  [ -n "$dev" ] || { echo "default route has no device: $default_route" >&2; exit 1; }

  jq -r '.[]' "$cidrs_file" | while IFS= read -r cidr; do
    add_route "$cidr" "$gateway" "$dev"
  done

  local ssh_peer=""
  if [ -n "$${SSH_CONNECTION:-}" ]; then
    ssh_peer="$${SSH_CONNECTION%% *}"
  elif [ -n "$${SSH_CLIENT:-}" ]; then
    ssh_peer="$${SSH_CLIENT%% *}"
  fi
  if printf '%s' "$ssh_peer" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    add_route "$ssh_peer/32" "$gateway" "$dev"
  fi
}

case "$${1:-setup}" in
  setup)
    setup_routes
    ;;
  *)
    echo "usage: agent-stack-vpn-routes setup" >&2
    exit 64
    ;;
esac
EOF
  chmod 0755 "$routes_path"
}

write_openvpn_config() {
  local tmp_config
  tmp_config="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 20 "$OPENVPN_CONFIG_URL" -o "$tmp_config"
  grep -qE '^[[:space:]]*client[[:space:]]*$' "$tmp_config" || fail "downloaded OpenVPN config does not look like a client config"

  awk '
    /^[[:space:]]*auth-user-pass([[:space:]]|$)/ { next }
    /^[[:space:]]*auth-nocache([[:space:]]|$)/ { next }
    { print }
  ' "$tmp_config" > "$config_dir/openvpn.conf"
  rm -f "$tmp_config"

  cat >> "$config_dir/openvpn.conf" <<'EOF'
auth-user-pass /etc/agent-stack-vpn/auth.txt
auth-nocache
EOF
  chmod 0600 "$config_dir/openvpn.conf"
}

write_systemd_unit() {
  cat > "$service_path" <<'EOF'
[Unit]
Description=AgentStack host VPN tunnel
Wants=network-online.target
After=network-online.target
Before=agent-stack.service

[Service]
Type=simple
ExecStartPre=/usr/local/bin/agent-stack-vpn-routes setup
ExecStart=/usr/sbin/openvpn --config /etc/agent-stack-vpn/openvpn.conf
Restart=always
RestartSec=10
RuntimeDirectory=agent-stack-vpn

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$service_path"
}

configure_ipv6() {
  if [ "$VPN_DISABLE_IPV6" != "true" ]; then
    rm -f /etc/sysctl.d/99-agent-stack-vpn-ipv6.conf
    return 0
  fi

  cat > /etc/sysctl.d/99-agent-stack-vpn-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-agent-stack-vpn-ipv6.conf >/dev/null || true
}

wait_vpn_online() {
  for _ in $(seq 1 30); do
    if systemctl is-active --quiet agent-stack-vpn.service && ip -o link show | grep -Eq ': tun[0-9]+@?'; then
      log "Host VPN tunnel is active."
      if [ -n "$VPN_HEALTHCHECK_URL" ]; then
        log "Current public egress IP: $(curl -fsS --max-time 8 "$VPN_HEALTHCHECK_URL" 2>/dev/null || echo unknown)"
      fi
      return 0
    fi
    sleep 2
  done
  systemctl status --no-pager agent-stack-vpn.service || true
  fail "host VPN tunnel did not become active"
}

enable_vpn() {
  [ "$VPN_PROVIDER" = "nordvpn_openvpn" ] || fail "unsupported vpn_provider=$VPN_PROVIDER"
  [ -n "$OPENVPN_CONFIG_URL" ] || fail "vpn_openvpn_config_url is required"
  [ -n "$staging" ] || fail "staging path is required"
  [ -s "$staging/vpn-auth.txt" ] || fail "vpn-auth.txt is missing or empty"

  install_openvpn
  install -d -m 0700 "$config_dir"
  install -m 0600 "$staging/vpn-auth.txt" "$config_dir/auth.txt"
  write_route_helper
  write_openvpn_config
  configure_ipv6
  write_systemd_unit
  systemctl daemon-reload
  systemctl enable --now agent-stack-vpn.service
  wait_vpn_online
}

case "$mode" in
  enable)
    if [ "$VPN_ENABLED" != "true" ]; then
      disable_vpn
      exit 0
    fi
    enable_vpn
    ;;
  disable)
    disable_vpn
    ;;
  *)
    echo "usage: $0 [enable STAGING|disable]" >&2
    exit 64
    ;;
esac
