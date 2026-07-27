#!/usr/bin/env bash
set -euo pipefail

app="$${AGENT_STACK_APP_ROOT:-/opt/agent-stack}"
compose="$app/docker-compose.yml"
home_root="$app/data/workspace/home"
residue="$home_root/workspace"
config="$app/workspace-rclone/rclone.conf"
recovery_config=/var/lib/agent-stack/workspace-drive-recovery/rclone.conf
[ ! -s "$recovery_config" ] || config="$recovery_config"
workspace_image=agent-stack-workspace:local
recovery_image=rclone/rclone:1.74.4
mountpoint_owner="$${AGENT_STACK_MOUNTPOINT_OWNER:-root}"
mountpoint_group="$${AGENT_STACK_MOUNTPOINT_GROUP:-root}"
drive_enabled='${workspace_drive_fuse_enabled}'
remote="$(printf '%s' '${workspace_drive_remote_base64}' | base64 -d)"

fail() {
  echo "[workspace-drive] ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: agent-stack-workspace-drive <command>

Read-only commands:
  status                 Show container and mount health.
  doctor                 Check host prerequisites, config shape, health, and local residue.
  recovery-dry-run       Preview copying local residue to Drive; changes nothing.

Explicit recovery commands:
  recover-copy --confirm-upload
                         Copy the entire local residue tree to Drive and verify it.
                         This never deletes either side.
  quarantine --confirm-quarantine
                         With the workspace stopped, move local residue aside and
                         recreate the protected empty mountpoint.
EOF
}

require_enabled() {
  [ "$drive_enabled" = "true" ] || fail "workspace Drive FUSE is not enabled by Terraform"
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
  ' "$config"
}

validate_config() {
  [ -s "$config" ] || fail "missing rclone config: $config"
  [ "$(stat -c '%a' "$config")" = "600" ] || fail "$config must have mode 0600"
  local remote_name
  remote_name="$${remote%%:*}"
  [ "$(config_value "$remote_name" type)" = "drive" ] || fail "remote '$remote_name' must have type=drive"
  [ -n "$(config_value "$remote_name" client_id)" ] || fail "remote '$remote_name' requires a custom client_id"
  [ -n "$(config_value "$remote_name" client_secret)" ] || fail "remote '$remote_name' requires a custom client_secret"
}

residue_has_files() {
  [ -d "$residue" ] && find "$residue" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

workspace_container_id() {
  docker compose -f "$compose" ps -q workspace 2>/dev/null || true
}

workspace_is_running() {
  local container_id
  container_id="$(workspace_container_id)"
  [ -n "$container_id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" = "true" ]
}

run_rclone() {
  local config_dir config_name
  config_dir="$(dirname "$config")"
  config_name="$(basename "$config")"
  docker run --rm \
    --entrypoint /usr/local/bin/rclone \
    -v "$config_dir:/etc/rclone" \
    -v "$home_root:/workspace-home:ro" \
    "$recovery_image" "$@" --config "/etc/rclone/$config_name"
}

print_residue_summary() {
  if residue_has_files; then
    echo "Local residue: PRESENT (deployment remains blocked)"
    find "$residue" -mindepth 1 -maxdepth 2 -printf '%P\n' 2>/dev/null | sed -n '1,50p'
  else
    echo "Local residue: none"
  fi
}

status() {
  if [ "$drive_enabled" != "true" ]; then
    echo "Workspace Drive FUSE: disabled"
    return 0
  fi
  local container_id health state
  container_id="$(workspace_container_id)"
  if [ -z "$container_id" ]; then
    echo "Workspace container: absent"
  else
    state="$(docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)"
    echo "Workspace container: $state (health: $health)"
    if [ "$state" = "running" ]; then
      if docker exec "$container_id" /usr/local/bin/workspace-drive-healthcheck >/dev/null 2>&1; then
        echo "Drive mount: healthy"
      else
        echo "Drive mount: unavailable"
      fi
    fi
  fi
  print_residue_summary
}

doctor() {
  require_enabled
  local failed=0
  if [ -c /dev/fuse ]; then
    echo "[ok] /dev/fuse is available"
  else
    echo "[fail] /dev/fuse is unavailable"
    failed=1
  fi
  if docker image inspect "$workspace_image" >/dev/null 2>&1; then
    echo "[ok] workspace image exists"
  else
    echo "[fail] workspace image is missing"
    failed=1
  fi
  if validate_config; then
    echo "[ok] rclone Drive config uses a custom OAuth client"
  else
    failed=1
  fi
  if residue_has_files; then
    echo "[fail] local files exist beneath the FUSE mountpoint"
    echo "       Run: sudo agent-stack-workspace-drive recovery-dry-run"
    failed=1
  else
    echo "[ok] underlying mountpoint is empty"
  fi
  if workspace_is_running; then
    local container_id
    container_id="$(workspace_container_id)"
    if docker exec "$container_id" /usr/local/bin/workspace-drive-healthcheck >/dev/null 2>&1; then
      echo "[ok] workspace container reports a healthy Drive mount"
    else
      echo "[fail] workspace container is running without a healthy Drive mount"
      failed=1
    fi
  else
    echo "[fail] workspace container is not running"
    failed=1
  fi
  return "$failed"
}

recovery_dry_run() {
  require_enabled
  validate_config
  residue_has_files || fail "no local residue was found at $residue"
  echo "Preview only: copying the entire local tree to $remote with no filters or deletes."
  run_rclone copy /workspace-home/workspace "$remote" \
    --links \
    --create-empty-src-dirs \
    --dry-run \
    --verbose
}

recover_copy() {
  require_enabled
  [ "$${1:-}" = "--confirm-upload" ] || fail "recover-copy requires --confirm-upload"
  validate_config
  residue_has_files || fail "no local residue was found at $residue"
  echo "Copying the entire local residue tree to $remote. Nothing will be deleted."
  run_rclone copy /workspace-home/workspace "$remote" \
    --links \
    --create-empty-src-dirs \
    --verbose
  echo "Verifying that every local file exists remotely with the same size..."
  run_rclone check /workspace-home/workspace "$remote" \
    --links \
    --one-way \
    --size-only
  echo "Recovery copy verified. Review it in Drive, then run quarantine explicitly if desired."
}

quarantine() {
  require_enabled
  [ "$${1:-}" = "--confirm-quarantine" ] || fail "quarantine requires --confirm-quarantine"
  workspace_is_running && fail "stop the workspace container before quarantining residue"
  residue_has_files || fail "no local residue was found at $residue"
  local destination
  destination="$home_root/workspace.local-recovery-$(date -u +%Y%m%dT%H%M%SZ)"
  [ ! -e "$destination" ] || fail "quarantine destination already exists: $destination"
  mv "$residue" "$destination"
  install -d -m 0000 -o "$mountpoint_owner" -g "$mountpoint_group" "$residue"
  echo "Moved local residue to: $destination"
  echo "The quarantined copy is recoverable and has not been deleted."
}

command="$${1:-}"
shift || true
case "$command" in
  status)
    status
    ;;
  doctor)
    doctor
    ;;
  recovery-dry-run)
    recovery_dry_run
    ;;
  recover-copy)
    recover_copy "$@"
    ;;
  quarantine)
    quarantine "$@"
    ;;
  help|-h|--help|"")
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
