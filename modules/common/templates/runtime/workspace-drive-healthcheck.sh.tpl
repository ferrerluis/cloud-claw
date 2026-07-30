#!/usr/bin/env bash
set -euo pipefail

pgrep -x sshd >/dev/null

if [ "$${WORKSPACE_DRIVE_FUSE_ENABLED:-false}" != "true" ]; then
  exit 0
fi

username="$${WORKSPACE_USERNAME:-user}"
home_dir="$(getent passwd "$username" | cut -d: -f6)"
mountpoint="$home_dir/workspace"
fs_type="$(findmnt -M "$mountpoint" -n -o FSTYPE 2>/dev/null || true)"

case "$fs_type" in
  fuse.rclone|fuse)
    ;;
  *)
    echo "workspace Drive FUSE mount is unavailable" >&2
    exit 1
    ;;
esac

pgrep -x rclone >/dev/null
timeout 5 stat "$mountpoint" >/dev/null

stats="$(timeout 5 rclone rc --url http://127.0.0.1:5572 core/stats 2>/dev/null)"
printf '%s' "$stats" | jq -e '
  (.errors // 0) == 0 and
  (.fatalError // false) == false
' >/dev/null || {
  echo "rclone reports a transfer or fatal error" >&2
  exit 1
}
