#!/usr/bin/env bash
set -euo pipefail

username="$${WORKSPACE_USERNAME:-user}"
password="$${WORKSPACE_PASSWORD:-}"

if [ -z "$password" ]; then
  echo "WORKSPACE_PASSWORD is required" >&2
  exit 1
fi

if ! printf '%s' "$username" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  echo "invalid WORKSPACE_USERNAME: $username" >&2
  exit 1
fi

if [ "$username" = "root" ]; then
  echo "WORKSPACE_USERNAME cannot be root" >&2
  exit 1
fi

if ! id "$username" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$username"
fi

home_dir="$(getent passwd "$username" | cut -d: -f6)"
install -d -m 0700 -o "$username" -g "$username" "$home_dir/.ssh"
install -d -m 0700 -o "$username" -g "$username" "$home_dir/.codex"
chown -R "$username:$username" "$home_dir"

printf '%s:%s\n' "$username" "$password" | chpasswd

authorized_keys_b64="$${WORKSPACE_AUTHORIZED_KEYS_BASE64:-}"
authorized_keys_file="$home_dir/.ssh/authorized_keys"
pubkey_auth="no"
if [ -n "$authorized_keys_b64" ]; then
  if ! printf '%s' "$authorized_keys_b64" | base64 -d >"$authorized_keys_file"; then
    echo "invalid WORKSPACE_AUTHORIZED_KEYS_BASE64" >&2
    exit 1
  fi
  if [ -s "$authorized_keys_file" ]; then
    pubkey_auth="yes"
  fi
else
  : >"$authorized_keys_file"
fi
chown "$username:$username" "$authorized_keys_file"
chmod 0600 "$authorized_keys_file"

cat >/etc/profile.d/agent-stack-workspace.sh <<EOF
export CODEX_HOME="$home_dir/.codex"
export PATH="/usr/local/bin:\$PATH"
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

ssh-keygen -A
exec /usr/sbin/sshd -D -e
