#!/usr/bin/env bash
set -euo pipefail

mode="$${1:-enable}"
staging="$${2:-}"

VPN_ENABLED="${vpn_enabled}"
VPN_PROVIDER="${vpn_provider}"
NORDVPN_CONNECT_TARGET="${vpn_nordvpn_connect_target}"
VPN_BYPASS_CIDRS_JSON='${vpn_bypass_cidrs_json}'
VPN_DISABLE_IPV6="${vpn_disable_ipv6}"
VPN_HEALTHCHECK_URL="${vpn_healthcheck_url}"

app=/opt/agent-stack
openvpn_backend="$app/agent-stack-vpn-openvpn"
config_dir=/etc/agent-stack-vpn
service_path=/etc/systemd/system/agent-stack-vpn.service
routes_path=/usr/local/bin/agent-stack-vpn-routes
rollback_dir=/var/lib/agent-stack/vpn-rollback
rollback_service=/etc/systemd/system/agent-stack-vpn-rollback.service
rollback_timer=/etc/systemd/system/agent-stack-vpn-rollback.timer
managed_allowlist="$config_dir/nordlynx-allowlist-cidrs"

log() {
  echo "[vpn] $*"
}

fail() {
  echo "[vpn] ERROR: $*" >&2
  exit 1
}

nordvpn_command() {
  command -v nordvpn >/dev/null 2>&1
}

wait_nordvpnd() {
  for _ in $(seq 1 30); do
    if systemctl is-active --quiet nordvpnd.service &&
       { [ -S /run/nordvpn/nordvpnd.sock ] || nordvpn status >/dev/null 2>&1; }; then
      return 0
    fi
    sleep 1
  done
  systemctl status --no-pager nordvpnd.service || true
  fail "NordVPN daemon did not become ready"
}

install_nordvpn() {
  if nordvpn_command; then
    systemctl enable --now nordvpnd.service
    wait_nordvpnd
    return 0
  fi

  log "Installing the official NordVPN Linux package."
  export DEBIAN_FRONTEND=noninteractive
  local release_deb
  release_deb="$(mktemp --suffix=.deb)"
  curl -fsSL --retry 3 --connect-timeout 20 \
    https://repo.nordvpn.com/deb/nordvpn/debian/pool/main/n/nordvpn-release/nordvpn-release_1.0.0_all.deb \
    -o "$release_deb"
  dpkg -i "$release_deb"
  rm -f "$release_deb"
  apt-get update
  apt-get install -y nordvpn
  systemctl enable --now nordvpnd.service
  wait_nordvpnd
}

nordvpn_logged_in() {
  local account_output
  account_output="$(nordvpn account 2>&1 || true)"
  [ -n "$account_output" ] && ! printf '%s\n' "$account_output" | grep -qiE 'not logged in|log in to proceed|please log in'
}

login_nordvpn() {
  local token_file="$1"
  if nordvpn_logged_in; then
    log "NordVPN Linux app is already authenticated."
    rm -f "$token_file"
    return 0
  fi

  [ -s "$token_file" ] || fail "vpn-token.txt is missing or empty"
  local token
  token="$(tr -d '\r\n' < "$token_file")"
  [ -n "$token" ] || fail "vpn-token.txt did not contain a token"
  log "Authenticating the headless NordVPN Linux app."
  nordvpn login --token "$token" >/dev/null
  unset token
  rm -f "$token_file"
  nordvpn_logged_in || fail "NordVPN login did not persist"
}

nord_allowlist() {
  local action="$1"
  local cidr="$2"
  if nordvpn allowlist "$action" subnet "$cidr" >/dev/null 2>&1; then
    return 0
  fi
  nordvpn whitelist "$action" subnet "$cidr" >/dev/null 2>&1
}

configure_nord_allowlist() {
  install -d -m 0700 "$config_dir"

  if [ -f "$managed_allowlist" ]; then
    while IFS= read -r cidr; do
      [ -n "$cidr" ] || continue
      nord_allowlist remove "$cidr" || true
    done < "$managed_allowlist"
  fi

  local next_allowlist
  next_allowlist="$(mktemp)"
  printf '%s\n' '100.64.0.0/10' > "$next_allowlist"
  jq -r '.[]' <<< "$VPN_BYPASS_CIDRS_JSON" >> "$next_allowlist"
  sort -u -o "$next_allowlist" "$next_allowlist"

  while IFS= read -r cidr; do
    [ -n "$cidr" ] || continue
    nord_allowlist add "$cidr"
  done < "$next_allowlist"

  install -m 0600 "$next_allowlist" "$managed_allowlist"
  rm -f "$next_allowlist"
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

configure_nordlynx_settings() {
  nordvpn set autoconnect off >/dev/null
  nordvpn set technology NordLynx >/dev/null
  nordvpn set killswitch off >/dev/null
  nordvpn set threatprotectionlite off >/dev/null || true
  nordvpn set meshnet off >/dev/null || true
  nordvpn set lan-discovery disable >/dev/null || true
  configure_nord_allowlist
  configure_ipv6
}

set_nordlynx_autoconnect() {
  if [ -n "$NORDVPN_CONNECT_TARGET" ]; then
    nordvpn set autoconnect on "$NORDVPN_CONNECT_TARGET" >/dev/null
  else
    nordvpn set autoconnect on >/dev/null
  fi
}

connect_nordlynx() {
  wait_nordvpnd
  nordvpn_logged_in || fail "NordVPN Linux app is not authenticated"
  set_nordlynx_autoconnect
  if [ -n "$NORDVPN_CONNECT_TARGET" ]; then
    nordvpn connect "$NORDVPN_CONNECT_TARGET" >/dev/null
  else
    nordvpn connect >/dev/null
  fi

  for _ in $(seq 1 30); do
    if nordvpn status 2>/dev/null | grep -qi '^Status:[[:space:]]*Connected' &&
       nordvpn status 2>/dev/null | grep -qi '^Current technology:[[:space:]]*NORDLYNX' &&
       ip link show nordlynx >/dev/null 2>&1; then
      log "NordLynx tunnel is connected."
      return 0
    fi
    sleep 2
  done
  nordvpn status || true
  fail "NordLynx tunnel did not become healthy"
}

disconnect_nordlynx() {
  if ! nordvpn_command; then
    return 0
  fi
  systemctl start nordvpnd.service >/dev/null 2>&1 || true
  nordvpn set autoconnect off >/dev/null 2>&1 || true
  nordvpn disconnect >/dev/null 2>&1 || true
}

write_nordlynx_service() {
  cat > "$service_path" <<'EOF'
[Unit]
Description=AgentStack host VPN tunnel (NordLynx)
Wants=network-online.target
Requires=nordvpnd.service
After=network-online.target nordvpnd.service
Before=agent-stack.service

[Service]
Type=oneshot
ExecStart=/opt/agent-stack/agent-stack-vpn nordlynx-start
ExecStop=/opt/agent-stack/agent-stack-vpn nordlynx-stop
RemainAfterExit=yes
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$service_path"
}

current_backend_is_openvpn() {
  [ -f "$service_path" ] && grep -q '/usr/sbin/openvpn' "$service_path"
}

arm_openvpn_rollback() {
  current_backend_is_openvpn || return 0
  [ ! -e "$rollback_dir/pending" ] || return 0

  log "Saving the OpenVPN backend and arming a 20-minute automatic rollback."
  rm -rf "$rollback_dir"
  install -d -m 0700 "$rollback_dir"
  cp -a "$service_path" "$rollback_dir/agent-stack-vpn.service"
  [ -d "$config_dir" ] && cp -a "$config_dir" "$rollback_dir/openvpn-config"
  [ -f "$routes_path" ] && cp -a "$routes_path" "$rollback_dir/agent-stack-vpn-routes"
  touch "$rollback_dir/pending"
  chmod 0600 "$rollback_dir/pending"

  cat > "$rollback_service" <<'EOF'
[Unit]
Description=Rollback AgentStack NordLynx canary to OpenVPN
ConditionPathExists=/var/lib/agent-stack/vpn-rollback/pending

[Service]
Type=oneshot
ExecStart=/opt/agent-stack/agent-stack-vpn rollback-if-pending
EOF

  local rollback_at
  rollback_at="$(date -u -d '+20 minutes' '+%Y-%m-%d %H:%M:%S UTC')"
  cat > "$rollback_timer" <<EOF
[Unit]
Description=Automatic AgentStack NordLynx canary rollback

[Timer]
OnCalendar=$rollback_at
Persistent=true
AccuracySec=1s
Unit=agent-stack-vpn-rollback.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$rollback_service" "$rollback_timer"
  systemctl daemon-reload
  systemctl enable --now agent-stack-vpn-rollback.timer
}

clear_rollback_timer() {
  systemctl disable --now agent-stack-vpn-rollback.timer 2>/dev/null || true
  rm -f "$rollback_service" "$rollback_timer"
  systemctl daemon-reload || true
}

confirm_nordlynx() {
  nordvpn status 2>/dev/null | grep -qi '^Status:[[:space:]]*Connected' || fail "NordLynx is not connected"
  nordvpn status 2>/dev/null | grep -qi '^Current technology:[[:space:]]*NORDLYNX' || fail "NordVPN is connected with a non-NordLynx technology"
  ip link show nordlynx >/dev/null 2>&1 || fail "nordlynx interface is missing"
  rm -f "$rollback_dir/pending"
  clear_rollback_timer
  log "NordLynx canary confirmed; automatic rollback is disarmed."
}

restore_openvpn() {
  [ -f "$rollback_dir/agent-stack-vpn.service" ] || fail "OpenVPN rollback service backup is missing"
  log "Rolling the host VPN back to OpenVPN."
  disconnect_nordlynx
  systemctl disable --now agent-stack-vpn.service 2>/dev/null || true
  systemctl disable --now nordvpnd.service 2>/dev/null || true

  rm -rf "$config_dir"
  if [ -d "$rollback_dir/openvpn-config" ]; then
    cp -a "$rollback_dir/openvpn-config" "$config_dir"
  fi
  install -d -m 0700 "$config_dir"
  printf '%s\n' 'nordvpn_openvpn' > "$config_dir/provider"
  chmod 0600 "$config_dir/provider"
  if [ -f "$rollback_dir/agent-stack-vpn-routes" ]; then
    cp -a "$rollback_dir/agent-stack-vpn-routes" "$routes_path"
    chmod 0755 "$routes_path"
  fi
  cp -a "$rollback_dir/agent-stack-vpn.service" "$service_path"
  chmod 0644 "$service_path"
  rm -f "$rollback_dir/pending"
  clear_rollback_timer
  systemctl enable --now tailscaled.service 2>/dev/null || true
  systemctl restart tailscaled.service 2>/dev/null || true
  systemctl enable --now agent-stack-vpn.service
  systemctl restart agent-stack.service || true
  log "OpenVPN rollback completed."
}

enable_nordlynx() {
  [ -n "$staging" ] || fail "staging path is required"
  local token_file="$staging/vpn-token.txt"
  local transition_armed=false
  trap 'rm -f "$token_file"' EXIT

  install_nordvpn
  login_nordvpn "$token_file"
  configure_nordlynx_settings
  if current_backend_is_openvpn; then
    arm_openvpn_rollback
    transition_armed=true
  fi

  # Do not let service traffic use the original Hetzner egress during the
  # access-safe interval between stopping OpenVPN and confirming NordLynx.
  systemctl stop agent-stack.service 2>/dev/null || true
  if ! systemctl disable --now agent-stack-vpn.service 2>/dev/null; then
    log "Existing VPN service was not active."
  fi
  write_nordlynx_service
  install -d -m 0700 "$config_dir"
  printf '%s\n' 'nordvpn_nordlynx' > "$config_dir/provider"
  chmod 0600 "$config_dir/provider"
  systemctl daemon-reload

  if ! systemctl enable --now agent-stack-vpn.service; then
    if [ "$transition_armed" = "true" ]; then
      restore_openvpn
    fi
    fail "NordLynx service failed to start"
  fi
  trap - EXIT
}

enable_openvpn() {
  if [ -f "$service_path" ] && grep -q 'nordlynx-start' "$service_path"; then
    systemctl stop agent-stack.service 2>/dev/null || true
  fi
  disconnect_nordlynx
  systemctl disable --now nordvpnd.service 2>/dev/null || true
  rm -f "$rollback_dir/pending"
  clear_rollback_timer
  [ -x "$openvpn_backend" ] || fail "OpenVPN backend is missing"
  "$openvpn_backend" enable "$staging"
}

disable_vpn() {
  disconnect_nordlynx
  systemctl disable --now nordvpnd.service 2>/dev/null || true
  rm -f "$rollback_dir/pending"
  clear_rollback_timer
  if [ -x "$openvpn_backend" ]; then
    "$openvpn_backend" disable || true
  else
    systemctl disable --now agent-stack-vpn.service 2>/dev/null || true
    rm -f "$service_path"
  fi
  rm -rf "$config_dir"
  rm -f /etc/sysctl.d/99-agent-stack-vpn-ipv6.conf
  systemctl daemon-reload || true
}

show_status() {
  local provider="$VPN_PROVIDER"
  if [ -s "$config_dir/provider" ]; then
    provider="$(head -n 1 "$config_dir/provider")"
  fi
  echo "configured_provider=$provider"
  echo "service_active=$(systemctl is-active agent-stack-vpn.service 2>/dev/null || true)"
  if nordvpn_command; then
    nordvpn --version 2>/dev/null || true
  fi
  if [ "$provider" = "nordvpn_nordlynx" ] && nordvpn_command; then
    nordvpn status 2>/dev/null || true
  fi
  echo "tunnel_links:"
  ip -o link show 2>/dev/null | grep -E ': (tun[0-9]+|nordlynx)@?' || true
  echo "egress_ip=$(curl -fsS --max-time 8 "$VPN_HEALTHCHECK_URL" 2>/dev/null || true)"
  echo "rollback_pending=$([ -e "$rollback_dir/pending" ] && echo true || echo false)"
}

case "$mode" in
  enable)
    if [ "$VPN_ENABLED" != "true" ]; then
      disable_vpn
      exit 0
    fi
    case "$VPN_PROVIDER" in
      nordvpn_openvpn) enable_openvpn ;;
      nordvpn_nordlynx) enable_nordlynx ;;
      *) fail "unsupported vpn_provider=$VPN_PROVIDER" ;;
    esac
    ;;
  disable)
    disable_vpn
    ;;
  nordlynx-start)
    connect_nordlynx
    ;;
  nordlynx-stop)
    disconnect_nordlynx
    ;;
  confirm)
    confirm_nordlynx
    ;;
  rollback)
    restore_openvpn
    ;;
  rollback-if-pending)
    [ -e "$rollback_dir/pending" ] && restore_openvpn
    ;;
  status)
    show_status
    ;;
  *)
    echo "usage: $0 [enable STAGING|disable|status|confirm|rollback]" >&2
    exit 64
    ;;
esac
