#!/usr/bin/env bash
set -euo pipefail

username="$${WORKSPACE_USERNAME:-user}"
password="$${WORKSPACE_PASSWORD:-}"
drive_enabled="$${WORKSPACE_DRIVE_FUSE_ENABLED:-false}"
drive_remote="$(printf '%s' "$${WORKSPACE_DRIVE_REMOTE_BASE64:-d29ya3NwYWNlLWRyaXZlOg==}" | base64 -d)"
drive_config="$${WORKSPACE_DRIVE_CONFIG:-/etc/rclone/rclone.conf}"
vfs_cache_max_size="$${WORKSPACE_DRIVE_VFS_CACHE_MAX_SIZE:-10G}"
vfs_cache_min_free_space="$${WORKSPACE_DRIVE_VFS_CACHE_MIN_FREE_SPACE:-2G}"
rclone_pid=""
sshd_pid=""

fail() {
  echo "[workspace] ERROR: $*" >&2
  exit 1
}

drive_is_mounted() {
  local mountpoint="$1"
  local fs_type
  fs_type="$(findmnt -M "$mountpoint" -n -o FSTYPE 2>/dev/null || true)"
  case "$fs_type" in
    fuse.rclone|fuse)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

config_value() {
  local section="$1"
  local key="$2"
  awk -v section="[$section]" -v wanted="$key" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    /^[[:space:]]*\[/ {
      current=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
      next
    }
    current == section {
      equals=index($0, "=")
      if (equals == 0) next
      candidate=trim(substr($0, 1, equals - 1))
      if (candidate == wanted) {
        print trim(substr($0, equals + 1))
        exit
      }
    }
  ' "$drive_config"
}

cleanup() {
  trap - EXIT INT TERM
  if [ -n "$sshd_pid" ] && kill -0 "$sshd_pid" 2>/dev/null; then
    kill -TERM "$sshd_pid" 2>/dev/null || true
    wait "$sshd_pid" 2>/dev/null || true
  fi
  if [ -n "$rclone_pid" ] && kill -0 "$rclone_pid" 2>/dev/null; then
    kill -TERM "$rclone_pid" 2>/dev/null || true
    wait "$rclone_pid" 2>/dev/null || true
  fi
  if [ -n "$${home_dir:-}" ] && drive_is_mounted "$home_dir/workspace"; then
    fusermount3 -uz "$home_dir/workspace" 2>/dev/null || true
  fi
}

trap cleanup EXIT
trap 'exit 143' INT TERM

if [ -z "$password" ]; then
  fail "WORKSPACE_PASSWORD is required"
fi

if ! printf '%s' "$username" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  fail "invalid WORKSPACE_USERNAME: $username"
fi

if [ "$username" = "root" ]; then
  fail "WORKSPACE_USERNAME cannot be root"
fi

if ! id "$username" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$username"
fi

home_dir="$(getent passwd "$username" | cut -d: -f6)"
user_uid="$(id -u "$username")"
user_gid="$(id -g "$username")"
chown "$username:$username" "$home_dir"
chmod 0700 "$home_dir"
install -d -m 0700 -o "$username" -g "$username" "$home_dir/.ssh"
install -d -m 0700 -o "$username" -g "$username" "$home_dir/.codex"

printf '%s:%s\n' "$username" "$password" | chpasswd

authorized_keys_b64="$${WORKSPACE_AUTHORIZED_KEYS_BASE64:-}"
authorized_keys_file="$home_dir/.ssh/authorized_keys"
pubkey_auth="no"
if [ -n "$authorized_keys_b64" ]; then
  if ! printf '%s' "$authorized_keys_b64" | base64 -d >"$authorized_keys_file"; then
    fail "invalid WORKSPACE_AUTHORIZED_KEYS_BASE64"
  fi
  if [ -s "$authorized_keys_file" ]; then
    pubkey_auth="yes"
  fi
else
  : >"$authorized_keys_file"
fi
chown "$username:$username" "$authorized_keys_file"
chmod 0600 "$authorized_keys_file"

host_key_dir="$${WORKSPACE_HOST_KEY_DIR:-/var/lib/agent-stack-workspace/ssh-host-keys}"
install -d -m 0700 -o root -g root "$host_key_dir"

ensure_host_key() {
  local type="$1"
  local bits="$${2:-}"
  local key="$host_key_dir/ssh_host_$${type}_key"

  if [ ! -f "$key" ]; then
    if [ -n "$bits" ]; then
      ssh-keygen -q -t "$type" -b "$bits" -N "" -f "$key"
    else
      ssh-keygen -q -t "$type" -N "" -f "$key"
    fi
  fi
  if [ ! -f "$key.pub" ]; then
    ssh-keygen -y -f "$key" >"$key.pub"
  fi

  chown root:root "$key" "$key.pub"
  chmod 0600 "$key"
  chmod 0644 "$key.pub"
}

ensure_host_key ed25519
ensure_host_key ecdsa
ensure_host_key rsa 4096

cat >/etc/ssh/sshd_config.d/98-agent-stack-workspace-host-keys.conf <<EOF
HostKey $host_key_dir/ssh_host_ed25519_key
HostKey $host_key_dir/ssh_host_ecdsa_key
HostKey $host_key_dir/ssh_host_rsa_key
EOF
chmod 0644 /etc/ssh/sshd_config.d/98-agent-stack-workspace-host-keys.conf

cat >/etc/profile.d/agent-stack-workspace.sh <<EOF
export CODEX_HOME="$home_dir/.codex"
export PATH="$home_dir/.local/bin:/usr/local/bin:\$PATH"
EOF
chmod 0644 /etc/profile.d/agent-stack-workspace.sh

cat >/etc/ssh/sshd_config.d/99-agent-stack-workspace.conf <<EOF
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication $pubkey_auth
AuthorizedKeysFile .ssh/authorized_keys
PermitRootLogin no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
EOF
printf 'SetEnv CODEX_HOME=%s\n' "$home_dir/.codex" >> /etc/ssh/sshd_config.d/99-agent-stack-workspace.conf
# SSH commands do not source /etc/profile.d.  Keep their Codex resolution
# identical to an interactive workspace shell so `ssh workspace codex` never
# accidentally selects the image fallback in /usr/local/bin.
printf 'SetEnv PATH=%s\n' "$home_dir/.local/bin:/usr/local/bin:/usr/bin:/bin" >> /etc/ssh/sshd_config.d/99-agent-stack-workspace.conf

cat >/usr/local/bin/agent-stack-diagnostics <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

key="$${AGENT_STACK_DIAGNOSTICS_KEY:-$HOME/.ssh/agent_stack_diagnostics}"
if [ ! -f "$key" ]; then
  echo "diagnostic key not found: $key" >&2
  exit 1
fi

exec ssh \
  -i "$key" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
  -o ConnectTimeout=10 \
  agent-stack-diagnostics@host.docker.internal \
  "$@"
EOF
chmod 0755 /usr/local/bin/agent-stack-diagnostics

start_workspace_drive_mount() {
  local helper="$home_dir/.local/bin/workspace-drive-mount"
  local log_dir="$home_dir/.cache/rclone"
  local log_file="$log_dir/workspace-mount-startup.log"

  [ "$${WORKSPACE_FUSE_ENABLED:-false}" = "true" ] || return 0
  [ -x "$helper" ] || return 0

  install -d -m 0700 -o "$username" -g "$username" "$log_dir"
  echo "[workspace] Starting workspace Drive mount via $helper..."
  if su -s /bin/bash "$username" -c "$helper start" </dev/null >>"$log_file" 2>&1; then
    echo "[workspace] Workspace Drive mount is active."
  else
    echo "[workspace] Workspace Drive mount did not start; continuing SSH startup. See $log_file." >&2
  fi
}

if [ "$${WORKSPACE_CODEX_AUTO_UPDATE_ENABLED:-false}" = "true" ]; then
  if ! /usr/local/libexec/agent-stack-workspace-codex-update --initialize "$username"; then
    echo "[workspace] WARNING: could not initialize the user-scoped Codex fallback; starting SSH without blocking access." >&2
  fi
fi

if [ "$drive_enabled" != "true" ]; then
  start_workspace_drive_mount
  trap - EXIT INT TERM
  exec /usr/sbin/sshd -D -e
fi

[ -c /dev/fuse ] || fail "/dev/fuse is unavailable; refusing to expose an unmounted workspace"
[ -s "$drive_config" ] || fail "rclone config is missing or empty: $drive_config"

remote_name="$${drive_remote%%:*}"
[ -n "$remote_name" ] || fail "WORKSPACE_DRIVE_REMOTE must name an rclone remote"
[ "$(config_value "$remote_name" type)" = "drive" ] || fail "rclone remote '$remote_name' must have type=drive"
[ -n "$(config_value "$remote_name" client_id)" ] || fail "rclone remote '$remote_name' must use a custom Google OAuth client_id"
[ -n "$(config_value "$remote_name" client_secret)" ] || fail "rclone remote '$remote_name' must use a custom Google OAuth client_secret"

mountpoint="$home_dir/workspace"
install -d -m 0000 -o root -g root "$mountpoint"
if find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
  fail "local files exist beneath $mountpoint; run 'sudo agent-stack-workspace-drive recovery-dry-run' on the host"
fi

cache_dir="$home_dir/.cache/rclone/vfs"
install -d -m 0700 -o "$username" -g "$username" "$home_dir/.cache" "$home_dir/.cache/rclone" "$cache_dir"

echo "[workspace-drive] Mounting $drive_remote at $mountpoint with rclone VFS full cache."
rclone mount "$drive_remote" "$mountpoint" \
  --config "$drive_config" \
  --allow-other \
  --uid "$user_uid" \
  --gid "$user_gid" \
  --file-perms 0600 \
  --dir-perms 0700 \
  --links \
  --cache-dir "$cache_dir" \
  --vfs-cache-mode full \
  --vfs-write-back 5s \
  --vfs-cache-max-age 168h \
  --vfs-cache-max-size "$vfs_cache_max_size" \
  --vfs-cache-min-free-space "$vfs_cache_min_free_space" \
  --dir-cache-time 5m \
  --poll-interval 30s \
  --rc \
  --rc-addr 127.0.0.1:5572 \
  --rc-no-auth \
  --stats 1m \
  --log-level INFO &
rclone_pid=$!

for attempt in $(seq 1 60); do
  if ! kill -0 "$rclone_pid" 2>/dev/null; then
    wait "$rclone_pid" || true
    fail "rclone exited before the workspace mount became ready"
  fi
  if drive_is_mounted "$mountpoint" \
      && timeout 5 stat "$mountpoint" >/dev/null 2>&1 \
      && timeout 5 rclone rc --url http://127.0.0.1:5572 rc/noop >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    fail "Drive mount did not become ready within 60 seconds"
  fi
  sleep 1
done

echo "[workspace-drive] Mount verified; starting SSH."
/usr/sbin/sshd -D -e &
sshd_pid=$!

failures=0
while kill -0 "$rclone_pid" 2>/dev/null && kill -0 "$sshd_pid" 2>/dev/null; do
  if /usr/local/bin/workspace-drive-healthcheck >/dev/null 2>&1; then
    failures=0
  else
    failures=$((failures + 1))
    echo "[workspace-drive] mount health failure $failures/3" >&2
    if [ "$failures" -ge 3 ]; then
      fail "Drive mount became unavailable; terminating the workspace to prevent local writes"
    fi
  fi
  sleep 5
done

if ! kill -0 "$rclone_pid" 2>/dev/null; then
  wait "$rclone_pid" || true
  fail "rclone exited; terminating the workspace"
fi
wait "$sshd_pid" || true
fail "sshd exited; terminating the workspace"
