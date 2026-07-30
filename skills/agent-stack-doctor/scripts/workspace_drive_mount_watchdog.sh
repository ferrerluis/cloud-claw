#!/usr/bin/env bash
set -euo pipefail

# Transitional repair helper for legacy AgentStack containers that mounted Drive
# through workspace_fuse_enabled. New deployments must use the Terraform-managed
# workspace_drive_fuse_enabled path instead.

REMOTE="${WORKSPACE_DRIVE_REMOTE:-workspace-drive:}"
MOUNTPOINT="${WORKSPACE_DRIVE_MOUNTPOINT:-$HOME/workspace}"
FILTER="${WORKSPACE_DRIVE_FILTER:-$HOME/.config/rclone/workspace-mount.filter}"
STATE_DIR="${WORKSPACE_DRIVE_STATE_DIR:-$HOME/.cache/rclone}"
CACHE_DIR="${WORKSPACE_DRIVE_CACHE_DIR:-$STATE_DIR/vfs}"
LOG_FILE="${WORKSPACE_DRIVE_LOG_FILE:-$STATE_DIR/workspace-mount.log}"
SUPERVISOR_LOG="${WORKSPACE_DRIVE_SUPERVISOR_LOG:-$STATE_DIR/workspace-mount-supervisor.log}"
PID_FILE="${WORKSPACE_DRIVE_PID_FILE:-$STATE_DIR/workspace-mount-supervisor.pid}"
LOCK_FILE="${WORKSPACE_DRIVE_LOCK_FILE:-$STATE_DIR/workspace-mount-supervisor.lock}"
BACKUP_PREFIX="${WORKSPACE_DRIVE_BACKUP_PREFIX:-$HOME/workspace.local-pre-rclone-mount}"
RC_ADDR="${WORKSPACE_DRIVE_RC_ADDR:-127.0.0.1:5572}"
RC_URL="http://$RC_ADDR"
HEALTH_TIMEOUT="${WORKSPACE_DRIVE_HEALTH_TIMEOUT:-5}"
HEALTH_INTERVAL="${WORKSPACE_DRIVE_HEALTH_INTERVAL:-5}"
HEALTH_FAILURE_LIMIT="${WORKSPACE_DRIVE_HEALTH_FAILURE_LIMIT:-3}"
READY_TIMEOUT="${WORKSPACE_DRIVE_READY_TIMEOUT:-45}"
START_TIMEOUT="${WORKSPACE_DRIVE_START_TIMEOUT:-75}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

managed_rclone_pid=""
started_rclone_pid=""

usage() {
  cat >&2 <<'USAGE'
Usage: workspace-drive-mount <command>

Commands:
  doctor      Diagnose rclone/FUSE prerequisites, supervisor, and mount health.
  status      Show supervisor, mount, and rclone health.
  probe       Test a temporary foreground rclone mount without touching ~/workspace.
  start       Ensure the singleton supervisor is running and wait for a healthy mount.
  supervise   Run the foreground rclone supervisor. Normally started by `start`.
  stop        Stop only this helper's supervisor/rclone mount and protect the mountpoint.
  prepare     Probe, copy newer local files to Drive, move local data aside, then start.
  guard       Exit non-zero unless both the supervisor and Drive mount are healthy.

This legacy helper refuses to use a plain local workspace as a fallback.
New AgentStack deployments must use workspace_drive_fuse_enabled instead.
USAGE
}

log() {
  printf '%s workspace-drive-mount: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR" "$CACHE_DIR"
  chmod 0700 "$STATE_DIR" "$CACHE_DIR"
}

check_prereqs() {
  local missing=0 command_name

  for command_name in rclone findmnt timeout flock fusermount3 setsid nohup; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'missing: %s is not installed or not on PATH\n' "$command_name" >&2
      missing=1
    }
  done

  if command -v rclone >/dev/null 2>&1; then
    timeout "$HEALTH_TIMEOUT" rclone listremotes 2>/dev/null | grep -Fxq "${REMOTE%%:*}:" || {
      printf 'missing: rclone remote %s is not configured\n' "${REMOTE%%:*}:" >&2
      missing=1
    }
  fi

  grep -qw fuse /proc/filesystems 2>/dev/null || {
    printf 'missing: kernel FUSE support is not visible in /proc/filesystems\n' >&2
    missing=1
  }

  test -e /dev/fuse || {
    printf 'missing: /dev/fuse is not exposed in this environment\n' >&2
    missing=1
  }

  test -f "$FILTER" || {
    printf 'missing: filter file does not exist: %s\n' "$FILTER" >&2
    missing=1
  }

  return "$missing"
}

require_prereqs() {
  check_prereqs || die "FUSE mount prerequisites are not satisfied"
}

mount_info_at() {
  local path="$1"
  findmnt -rn -M "$path" -o TARGET,SOURCE,FSTYPE 2>/dev/null || true
}

mount_record_exists_at() {
  test -n "$(mount_info_at "$1")"
}

is_expected_mount_at() {
  local path="$1" info target source fstype
  info="$(mount_info_at "$path")"
  test -n "$info" || return 1
  read -r target source fstype <<<"$info"
  test "$target" = "$path" || return 1
  test "$source" = "$REMOTE" || return 1
  case "$fstype" in
    fuse.rclone|fuse) return 0 ;;
    *) return 1 ;;
  esac
}

is_expected_mount() {
  is_expected_mount_at "$MOUNTPOINT"
}

mount_record_exists() {
  mount_record_exists_at "$MOUNTPOINT"
}

read_process_args() {
  local pid="$1"
  PROCESS_ARGS=()
  test -r "/proc/$pid/cmdline" || return 1
  mapfile -d '' -t PROCESS_ARGS <"/proc/$pid/cmdline" || true
  test "${#PROCESS_ARGS[@]}" -gt 0
}

pid_is_expected_rclone() {
  local pid="$1" index
  read_process_args "$pid" || return 1
  for ((index = 0; index + 3 < ${#PROCESS_ARGS[@]}; index++)); do
    if test "$(basename "${PROCESS_ARGS[$index]}")" = "rclone" \
      && test "${PROCESS_ARGS[$((index + 1))]}" = "mount" \
      && test "${PROCESS_ARGS[$((index + 2))]}" = "$REMOTE" \
      && test "${PROCESS_ARGS[$((index + 3))]}" = "$MOUNTPOINT"; then
      return 0
    fi
  done
  return 1
}

rclone_pid_for_mount() {
  local pid
  while IFS= read -r pid; do
    test -n "$pid" || continue
    if pid_is_expected_rclone "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(pgrep -u "$(id -u)" -x rclone 2>/dev/null || true)
  return 1
}

pid_is_expected_supervisor() {
  local pid="$1" index candidate
  read_process_args "$pid" || return 1
  for ((index = 0; index + 1 < ${#PROCESS_ARGS[@]}; index++)); do
    candidate="${PROCESS_ARGS[$index]}"
    if test "$(readlink -f "$candidate" 2>/dev/null || true)" = "$SCRIPT_PATH" \
      && test "${PROCESS_ARGS[$((index + 1))]}" = "supervise"; then
      return 0
    fi
  done
  return 1
}

supervisor_pid() {
  local pid
  test -s "$PID_FILE" || return 1
  read -r pid <"$PID_FILE"
  test -n "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  pid_is_expected_supervisor "$pid" || return 1
  printf '%s\n' "$pid"
}

supervisor_alive() {
  supervisor_pid >/dev/null
}

mount_endpoint_healthy() {
  local pid
  is_expected_mount || return 1
  timeout "$HEALTH_TIMEOUT" stat "$MOUNTPOINT" >/dev/null 2>&1 || return 1
  pid="$(rclone_pid_for_mount)" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  timeout "$HEALTH_TIMEOUT" rclone rc --url "$RC_URL" rc/noop >/dev/null 2>&1
}

guard() {
  supervisor_alive && mount_endpoint_healthy
}

protect_unmounted_mountpoint() {
  mount_record_exists && return 0
  mkdir -p "$MOUNTPOINT"
  chmod 0000 "$MOUNTPOINT"
}

prepare_mountpoint_for_mount() {
  mount_record_exists && {
    log "refusing to prepare a mountpoint that is already mounted: $MOUNTPOINT" >&2
    return 1
  }

  mkdir -p "$MOUNTPOINT"
  chmod 0700 "$MOUNTPOINT"
  if find "$MOUNTPOINT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    chmod 0000 "$MOUNTPOINT"
    log "$MOUNTPOINT contains local files; refusing to cover them with Drive" >&2
    return 1
  fi
}

terminate_pid() {
  local pid="$1" attempt
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for attempt in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -KILL "$pid" 2>/dev/null || true
}

terminate_expected_rclone() {
  local pid
  pid="$(rclone_pid_for_mount)" || return 0
  log "stopping rclone PID $pid"
  terminate_pid "$pid"
}

clear_expected_mount() {
  local attempt
  if mount_record_exists && ! is_expected_mount; then
    log "refusing to unmount unexpected filesystem: $(mount_info_at "$MOUNTPOINT")" >&2
    return 1
  fi
  is_expected_mount || return 0
  log "clearing FUSE mount record at $MOUNTPOINT"
  fusermount3 -uz "$MOUNTPOINT" 2>/dev/null || true
  for attempt in $(seq 1 20); do
    mount_record_exists || return 0
    sleep 0.25
  done
  log "FUSE mount record did not clear: $(mount_info_at "$MOUNTPOINT")" >&2
  return 1
}

launch_rclone() {
  rclone mount "$REMOTE" "$MOUNTPOINT" \
    --filter-from "$FILTER" \
    --links \
    --cache-dir "$CACHE_DIR" \
    --vfs-cache-mode full \
    --vfs-cache-max-size 20G \
    --vfs-cache-max-age 168h \
    --vfs-write-back 5s \
    --dir-cache-time 30s \
    --poll-interval 15s \
    --file-perms 0600 \
    --dir-perms 0700 \
    --rc \
    --rc-addr "$RC_ADDR" \
    --rc-no-auth \
    --log-file "$LOG_FILE" \
    --log-level INFO &
  started_rclone_pid=$!
  managed_rclone_pid="$started_rclone_pid"
  log "started foreground rclone PID $started_rclone_pid"
}

wait_for_mount_ready() {
  local attempt
  for attempt in $(seq 1 "$READY_TIMEOUT"); do
    if mount_endpoint_healthy; then
      return 0
    fi
    if test -n "$managed_rclone_pid" && ! kill -0 "$managed_rclone_pid" 2>/dev/null; then
      wait "$managed_rclone_pid" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
  return 1
}

attempt_recovery() {
  terminate_expected_rclone
  clear_expected_mount || return 1
  protect_unmounted_mountpoint
  prepare_mountpoint_for_mount || return 1
  launch_rclone
  if wait_for_mount_ready; then
    log "Drive mount is healthy"
    return 0
  fi

  log "rclone did not become healthy within ${READY_TIMEOUT}s" >&2
  if test -n "$managed_rclone_pid" && pid_is_expected_rclone "$managed_rclone_pid"; then
    terminate_pid "$managed_rclone_pid"
  fi
  managed_rclone_pid=""
  clear_expected_mount || true
  protect_unmounted_mountpoint
  return 1
}

supervisor_cleanup() {
  local current_pid=""
  trap - EXIT INT TERM
  set +e
  if test -n "$managed_rclone_pid" && pid_is_expected_rclone "$managed_rclone_pid"; then
    terminate_pid "$managed_rclone_pid"
  else
    current_pid="$(rclone_pid_for_mount 2>/dev/null || true)"
    test -z "$current_pid" || terminate_pid "$current_pid"
  fi
  clear_expected_mount
  protect_unmounted_mountpoint
  if test -s "$PID_FILE" && test "$(cat "$PID_FILE" 2>/dev/null)" = "$$"; then
    rm -f "$PID_FILE"
  fi
}

supervise() {
  local failures=0 backoff_index=0 backoff_seconds
  local -a backoffs=(5 15 30 60)

  require_prereqs
  ensure_state_dir
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "another supervisor already holds $LOCK_FILE"
    return 0
  fi

  printf '%s\n' "$$" >"$PID_FILE"
  chmod 0600 "$PID_FILE"
  trap supervisor_cleanup EXIT
  trap 'exit 143' INT TERM
  log "supervisor started as PID $$"

  while true; do
    if mount_endpoint_healthy; then
      failures=0
      backoff_index=0
      sleep "$HEALTH_INTERVAL"
      continue
    fi

    if mount_record_exists && ! is_expected_mount; then
      log "unexpected filesystem occupies $MOUNTPOINT: $(mount_info_at "$MOUNTPOINT")" >&2
      sleep "${backoffs[$backoff_index]}"
      if test "$backoff_index" -lt "$((${#backoffs[@]} - 1))"; then
        backoff_index=$((backoff_index + 1))
      fi
      continue
    fi

    if is_expected_mount; then
      failures=$((failures + 1))
      log "mount health failure $failures/$HEALTH_FAILURE_LIMIT"
      if test "$failures" -lt "$HEALTH_FAILURE_LIMIT"; then
        sleep "$HEALTH_INTERVAL"
        continue
      fi
    fi

    if attempt_recovery; then
      failures=0
      backoff_index=0
      sleep "$HEALTH_INTERVAL"
      continue
    fi

    backoff_seconds="${backoffs[$backoff_index]}"
    log "recovery failed; retrying in ${backoff_seconds}s" >&2
    sleep "$backoff_seconds"
    if test "$backoff_index" -lt "$((${#backoffs[@]} - 1))"; then
      backoff_index=$((backoff_index + 1))
    fi
  done
}

launch_supervisor() {
  ensure_state_dir
  nohup setsid "$SCRIPT_PATH" supervise </dev/null >>"$SUPERVISOR_LOG" 2>&1 &
}

start() {
  local attempt
  require_prereqs
  ensure_state_dir

  if ! supervisor_alive; then
    rm -f "$PID_FILE"
    launch_supervisor
  fi

  for attempt in $(seq 1 "$START_TIMEOUT"); do
    if guard; then
      status
      return 0
    fi
    if test "$attempt" -gt 3 && ! supervisor_alive; then
      die "supervisor exited before the mount became healthy; see $SUPERVISOR_LOG"
    fi
    sleep 1
  done
  die "mount did not become healthy within ${START_TIMEOUT}s; see $SUPERVISOR_LOG"
}

stop() {
  local pid="" attempt
  if pid="$(supervisor_pid 2>/dev/null)"; then
    log "stopping supervisor PID $pid"
    kill -TERM "$pid" 2>/dev/null || true
    for attempt in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
  else
    terminate_expected_rclone
    clear_expected_mount
    protect_unmounted_mountpoint
    rm -f "$PID_FILE"
  fi

  supervisor_alive && die "supervisor did not stop"
  is_expected_mount && die "Drive mount did not stop"
  log "supervisor stopped; unmounted workspace is protected"
}

status() {
  local pid="" rclone_pid="" healthy=0
  if pid="$(supervisor_pid 2>/dev/null)"; then
    printf 'Supervisor: running (PID %s)\n' "$pid"
  else
    printf 'Supervisor: not running\n'
  fi

  if mount_record_exists; then
    printf 'Mount: %s\n' "$(mount_info_at "$MOUNTPOINT")"
  else
    printf 'Mount: not mounted\n'
  fi

  if rclone_pid="$(rclone_pid_for_mount 2>/dev/null)"; then
    printf 'rclone: running (PID %s)\n' "$rclone_pid"
  else
    printf 'rclone: not running for %s\n' "$MOUNTPOINT"
  fi

  if guard; then
    printf 'Health: healthy\n'
    healthy=1
  else
    printf 'Health: unavailable\n'
  fi
  test "$healthy" -eq 1
}

doctor() {
  local rc=0
  check_prereqs || rc=1
  status || rc=1
  return "$rc"
}

probe() {
  local probe_dir probe_pid="" attempt ready=0
  require_prereqs
  ensure_state_dir
  probe_dir="$(mktemp -d /tmp/workspace-drive-mount-probe.XXXXXX)"

  rclone mount "$REMOTE" "$probe_dir" \
    --filter-from "$FILTER" \
    --links \
    --cache-dir "$CACHE_DIR" \
    --vfs-cache-mode full \
    --vfs-write-back 5s \
    --file-perms 0600 \
    --dir-perms 0700 \
    --log-file "$LOG_FILE" \
    --log-level INFO &
  probe_pid=$!

  for attempt in $(seq 1 "$READY_TIMEOUT"); do
    if is_expected_mount_at "$probe_dir" && timeout "$HEALTH_TIMEOUT" stat "$probe_dir" >/dev/null 2>&1; then
      ready=1
      break
    fi
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 1
  done

  terminate_pid "$probe_pid"
  if is_expected_mount_at "$probe_dir"; then
    fusermount3 -uz "$probe_dir" 2>/dev/null || true
  fi
  rmdir "$probe_dir" 2>/dev/null || true
  test "$ready" -eq 1 || die "temporary foreground rclone mount did not become healthy"
  log "temporary foreground rclone mount probe succeeded"
}

prepare() {
  local backup
  require_prereqs

  if is_expected_mount; then
    start
    return
  fi
  mount_record_exists && die "unexpected filesystem occupies $MOUNTPOINT: $(mount_info_at "$MOUNTPOINT")"
  test -d "$MOUNTPOINT" || die "$MOUNTPOINT does not exist"

  chmod 0700 "$MOUNTPOINT"
  probe
  backup="${BACKUP_PREFIX}-$(date -u +%Y%m%d-%H%M%S)"

  log "copying newer local workspace files to $REMOTE with filter $FILTER"
  rclone copy "$MOUNTPOINT" "$REMOTE" \
    --filter-from "$FILTER" \
    --links \
    --update \
    --stats-one-line \
    --log-file "$LOG_FILE" \
    --log-level INFO

  log "moving local workspace aside to $backup"
  mv "$MOUNTPOINT" "$backup"
  mkdir -p "$MOUNTPOINT"
  chmod 0000 "$MOUNTPOINT"
  start
  log "local backup retained at $backup"
}

main() {
  case "${1:-}" in
    doctor) doctor ;;
    status) status ;;
    probe) probe ;;
    start) start ;;
    supervise) supervise ;;
    stop) stop ;;
    prepare) prepare ;;
    guard) guard ;;
    -h|--help|help) usage ;;
    *) usage; return 2 ;;
  esac
}

if test "${WORKSPACE_DRIVE_SOURCE_ONLY:-false}" != "true"; then
  main "$@"
fi
