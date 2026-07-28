#!/usr/bin/env bash
set -euo pipefail

app="$${AGENT_STACK_APP_ROOT:-/opt/agent-stack}"
compose="$app/docker-compose.yml"
workspace_user="${workspace_username}"
timezone="${workspace_codex_auto_update_timezone}"
update_time="${workspace_codex_auto_update_time}"
recovery_enabled="${workspace_codex_auto_recover_interrupted_turns}"
state_dir=/var/lib/agent-stack/workspace-codex-update
ledger="$state_dir/ledger.jsonl"
lock_file="$state_dir/lock"
mode="$${1:---scheduled}"

case "$mode" in
  --scheduled) ;;
  *)
    echo "usage: agent-stack-workspace-codex-update --scheduled" >&2
    exit 64
    ;;
esac

if [ "$#" -ne 1 ]; then
  echo "usage: agent-stack-workspace-codex-update --scheduled" >&2
  exit 64
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "agent-stack workspace Codex maintenance must run as root" >&2
  exit 77
fi

install -d -m 0700 -o root -g root "$state_dir"
touch "$ledger"
chmod 0600 "$ledger"
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "[workspace-codex-update] another maintenance run is already active" >&2
  exit 0
fi

log() {
  printf '[workspace-codex-update] %s\n' "$*" >&2
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

record_event() {
  local event_id="$1"
  local phase="$2"
  local attempt="$3"
  local outcome="$4"
  local data="$5"
  local line

  # The ledger is observability, not a correctness dependency.  Once `codex
  # update` has switched a target, a full or unavailable ledger must never
  # strand the new CLI beside the old daemon before restart/rollback runs.
  if ! line="$(jq -cn \
    --arg at "$(now_utc)" \
    --arg event_id "$event_id" \
    --arg phase "$phase" \
    --argjson attempt "$attempt" \
    --arg outcome "$outcome" \
    --argjson data "$data" \
    '{at:$at,eventId:$event_id,phase:$phase,attempt:$attempt,outcome:$outcome,data:$data}')"; then
    log "could not serialize a maintenance ledger event; continuing safely"
    return 0
  fi
  if ! printf '%s\n' "$line" >>"$ledger"; then
    log "could not write a maintenance ledger event; continuing safely"
  fi
  return 0
}

result_metadata() {
  local result="$1"
  printf '%s' "$result" | jq -c '{ok:(.ok // false),action:(.action // ""),error:(.error // "")}' 2>/dev/null || printf '%s' '{}'
}

snapshot_metadata() {
  local result="$1"
  printf '%s' "$result" | jq -c '{snapshot:(.snapshot // [] | map({threadId,turnId,recoveryEligible}))}' 2>/dev/null || printf '%s' '{}'
}

update_metadata() {
  local result="$1"
  printf '%s' "$result" | jq -c '{before_version:(.before_version // ""),after_version:(.after_version // ""),changed:(.changed // false),target_changed:(.target_changed // false)}' 2>/dev/null || printf '%s' '{}'
}

is_retryable_pre_restart_failure() {
  local result="$1"
  local status="$2"
  local error=""

  [ "$status" -eq 75 ] && return 0
  error="$(printf '%s' "$result" | jq -r '.error // empty' 2>/dev/null || true)"
  # An absent or malformed result normally means docker exec, the container,
  # or the app-server control path disappeared. Those are bounded technical
  # retry cases. A structured error is retried only when it is explicitly one
  # of the helper's pre-restart transient failures.
  if [ -z "$error" ]; then
    return 0
  fi
  case "$error" in
    workspace_home_unavailable|socket_unavailable|proxy_unavailable|rpc_timeout|rpc_error|command_timeout|command_unavailable|command_failed|version_unavailable)
      return 0
      ;;
    *) return 1 ;;
  esac
}

workspace_container() {
  docker compose -f "$compose" ps -q workspace 2>/dev/null | head -n 1 || true
}

normalize_workspace_codex() {
  local cid="$1"
  docker exec --user root "$cid" \
    /usr/local/libexec/agent-stack-workspace-codex-update --normalize "$workspace_user" >/dev/null
}

control_call() {
  local cid="$1"
  local action="$2"

  docker exec \
    --user "$workspace_user" \
    --env "HOME=/home/$workspace_user" \
    --env "CODEX_HOME=/home/$workspace_user/.codex" \
    --env "PATH=/home/$workspace_user/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$cid" \
    /usr/local/libexec/agent-stack-workspace-codex-control "$action"
}

recovery_control_call() {
  local cid="$1"
  local event_id="$2"
  local thread_id="$3"
  local turn_id="$4"

  docker exec \
    --user "$workspace_user" \
    --env "HOME=/home/$workspace_user" \
    --env "CODEX_HOME=/home/$workspace_user/.codex" \
    --env "PATH=/home/$workspace_user/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    --env "AGENT_STACK_CODEX_CONTROL_RECOVERY_EVENT_ID=$event_id" \
    --env "AGENT_STACK_CODEX_CONTROL_RECOVERY_THREAD_ID=$thread_id" \
    --env "AGENT_STACK_CODEX_CONTROL_RECOVERY_TURN_ID=$turn_id" \
    "$cid" \
    /usr/local/libexec/agent-stack-workspace-codex-control recover
}

rollback_control_call() {
  local cid="$1"
  local previous_target="$2"
  local previous_version="$3"

  docker exec \
    --user "$workspace_user" \
    --env "HOME=/home/$workspace_user" \
    --env "CODEX_HOME=/home/$workspace_user/.codex" \
    --env "PATH=/home/$workspace_user/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    --env "AGENT_STACK_CODEX_CONTROL_PREVIOUS_TARGET=$previous_target" \
    --env "AGENT_STACK_CODEX_CONTROL_PREVIOUS_VERSION=$previous_version" \
    "$cid" \
    /usr/local/libexec/agent-stack-workspace-codex-control rollback
}

valid_identifier() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$'
}

recover_interrupted_turns() {
  local cid="$1"
  local event_id="$2"
  local attempt="$3"
  local snapshot="$4"
  local thread_id turn_id marker marker_key result metadata rc

  [ "$recovery_enabled" = "true" ] || return 0

  while IFS=$'\t' read -r thread_id turn_id; do
    [ -n "$thread_id" ] || continue
    if ! valid_identifier "$thread_id" || ! valid_identifier "$turn_id"; then
      record_event "$event_id" recovery "$attempt" skipped '{"reason":"invalid_snapshot_identifier"}'
      continue
    fi

    marker_key="$(printf '%s\000%s\000%s' "$event_id" "$thread_id" "$turn_id" | sha256sum | awk '{print $1}')"
    marker="$state_dir/recovery-$marker_key"
    if ! (umask 077; set -C; : >"$marker") 2>/dev/null; then
      record_event "$event_id" recovery "$attempt" skipped "$(jq -cn --arg thread_id "$thread_id" --arg turn_id "$turn_id" '{threadId:$thread_id,turnId:$turn_id,reason:"already_marked"}')"
      continue
    fi
    chmod 0600 "$marker"

    if result="$(recovery_control_call "$cid" "$event_id" "$thread_id" "$turn_id")"; then
      metadata="$(printf '%s' "$result" | jq -c '{recovered:(.recovered // false),thread_id:(.thread_id // ""),turn_id:(.turn_id // ""),error:(.error // "")}' 2>/dev/null || printf '%s' '{}')"
      record_event "$event_id" recovery "$attempt" complete "$metadata"
    else
      rc=$?
      metadata="$(result_metadata "$result")"
      record_event "$event_id" recovery "$attempt" failed "$metadata"
      log "a recovery action failed after the restart; it will not be retried"
    fi
  done < <(printf '%s' "$snapshot" | jq -r '.[] | select(.recoveryEligible == true) | [.threadId,.turnId] | @tsv' 2>/dev/null || true)
}

attempt_update() {
  local attempt="$1"
  local event_id="update-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  local cid preflight_result snapshot_result update_result restart_result rollback_result rollback_restart_result
  local snapshot update_data changed target_changed previous_target previous_version known_previous_target known_previous_version rc

  cid="$(workspace_container)"
  if [ -z "$cid" ]; then
    record_event "$event_id" preflight "$attempt" retryable '{"reason":"workspace_unavailable"}'
    log "workspace container is unavailable before the daemon restart"
    return 75
  fi

  if ! normalize_workspace_codex "$cid"; then
    record_event "$event_id" initialize "$attempt" failed '{"reason":"canonicalization_failed"}'
    log "workspace Codex canonicalization failed; daemon restart was not attempted"
    return 1
  fi

  # This deliberately starts only Codex's managed daemon.  A live unmanaged
  # app-server or an old hourly updater loop is terminal: the maintenance
  # worker must never take ownership of either one.
  if preflight_result="$(control_call "$cid" preflight)"; then
    if ! printf '%s' "$preflight_result" | jq -e '.ok == true and .action == "preflight"' >/dev/null 2>&1; then
      if is_retryable_pre_restart_failure "$preflight_result" 1; then
        record_event "$event_id" preflight "$attempt" retryable "$(result_metadata "$preflight_result")"
        return 75
      fi
      record_event "$event_id" preflight "$attempt" failed "$(result_metadata "$preflight_result")"
      return 1
    fi
  else
    rc=$?
    if is_retryable_pre_restart_failure "$preflight_result" "$rc"; then
      record_event "$event_id" preflight "$attempt" retryable "$(result_metadata "$preflight_result")"
      return 75
    fi
    record_event "$event_id" preflight "$attempt" failed "$(result_metadata "$preflight_result")"
    return 1
  fi
  record_event "$event_id" preflight "$attempt" ready "$(result_metadata "$preflight_result")"
  if ! known_previous_target="$(printf '%s' "$preflight_result" | jq -er '.current_target | strings | select(startswith("/"))')" || \
     ! known_previous_version="$(printf '%s' "$preflight_result" | jq -er '.version | strings | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))')"; then
    # Parsing happens before `codex update`, so a bad helper response cannot
    # leave a changed target without a known rollback reference.
    record_event "$event_id" preflight "$attempt" failed '{"reason":"missing_rollback_reference"}'
    return 1
  fi

  if snapshot_result="$(control_call "$cid" snapshot)"; then
    if ! printf '%s' "$snapshot_result" | jq -e '.ok == true and .action == "snapshot" and (.snapshot | type == "array")' >/dev/null 2>&1; then
      if is_retryable_pre_restart_failure "$snapshot_result" 1; then
        record_event "$event_id" snapshot "$attempt" retryable "$(result_metadata "$snapshot_result")"
        return 75
      fi
      record_event "$event_id" snapshot "$attempt" failed "$(result_metadata "$snapshot_result")"
      return 1
    fi
  else
    rc=$?
    if is_retryable_pre_restart_failure "$snapshot_result" "$rc"; then
      record_event "$event_id" snapshot "$attempt" retryable "$(result_metadata "$snapshot_result")"
      return 75
    fi
    record_event "$event_id" snapshot "$attempt" failed "$(result_metadata "$snapshot_result")"
    return 1
  fi
  snapshot="$(printf '%s' "$snapshot_result" | jq -c '.snapshot')"

  if update_result="$(control_call "$cid" update)"; then
    if ! printf '%s' "$update_result" | jq -e '.ok == true and .action == "update" and (.changed | type == "boolean")' >/dev/null 2>&1; then
      if is_retryable_pre_restart_failure "$update_result" 1; then
        record_event "$event_id" update "$attempt" retryable "$(result_metadata "$update_result")"
        return 75
      fi
      record_event "$event_id" update "$attempt" failed "$(result_metadata "$update_result")"
      return 1
    fi
  else
    rc=$?
    if is_retryable_pre_restart_failure "$update_result" "$rc"; then
      record_event "$event_id" update "$attempt" retryable "$(result_metadata "$update_result")"
      return 75
    fi
    record_event "$event_id" update "$attempt" failed "$(result_metadata "$update_result")"
    return 1
  fi

  update_data="$(update_metadata "$update_result")"
  changed=""
  if ! changed="$(printf '%s' "$update_result" | jq -r 'if (.changed | type) == "boolean" then (.changed | tostring) else empty end' 2>/dev/null)"; then
    changed=""
  fi
  if [ "$changed" != "true" ] && [ "$changed" != "false" ]; then
    # The update helper has already switched only after it can produce a
    # rollback reference.  Use the pre-update reference if transport/output
    # parsing fails in this root coordinator.
    record_event "$event_id" update "$attempt" failed "$update_data"
    if rollback_result="$(rollback_control_call "$cid" "$known_previous_target" "$known_previous_version")" && printf '%s' "$rollback_result" | jq -e '.ok == true and .action == "rollback"' >/dev/null 2>&1; then
      record_event "$event_id" rollback "$attempt" restored "$(result_metadata "$rollback_result")"
    else
      record_event "$event_id" rollback "$attempt" failed "$(result_metadata "$rollback_result")"
    fi
    return 1
  fi
  if [ "$changed" != "true" ]; then
    record_event "$event_id" update "$attempt" no_update "$update_data"
    log "Codex is already current; the app-server was not restarted"
    return 0
  fi

  previous_target="$(printf '%s' "$update_result" | jq -r '.previous_target // empty' 2>/dev/null || true)"
  previous_version="$(printf '%s' "$update_result" | jq -r '.before_version // empty' 2>/dev/null || true)"
  target_changed="$(printf '%s' "$update_result" | jq -r '.target_changed // false' 2>/dev/null || true)"
  if [ "$previous_target" != "$known_previous_target" ] || [ "$previous_version" != "$known_previous_version" ] || [ "$target_changed" != "true" ]; then
    record_event "$event_id" update "$attempt" failed "$update_data"
    log "Codex update changed version without a rollback-safe user release target; restoring the prior target and skipping daemon restart"
    if rollback_result="$(rollback_control_call "$cid" "$known_previous_target" "$known_previous_version")" && printf '%s' "$rollback_result" | jq -e '.ok == true and .action == "rollback"' >/dev/null 2>&1; then
      record_event "$event_id" rollback "$attempt" restored "$(result_metadata "$rollback_result")"
    else
      record_event "$event_id" rollback "$attempt" failed "$(result_metadata "$rollback_result")"
    fi
    return 1
  fi

  record_event "$event_id" snapshot "$attempt" captured "$(snapshot_metadata "$snapshot_result")"
  record_event "$event_id" update "$attempt" installed "$update_data"

  if restart_result="$(control_call "$cid" restart-verify)"; then
    if printf '%s' "$restart_result" | jq -e '.ok == true and .action == "restart-verify"' >/dev/null 2>&1; then
      record_event "$event_id" restart "$attempt" verified "$(result_metadata "$restart_result")"
      recover_interrupted_turns "$cid" "$event_id" "$attempt" "$snapshot"
      return 0
    fi
  fi

  record_event "$event_id" restart "$attempt" failed "$(result_metadata "$restart_result")"
  log "app-server restart verification failed; restoring the prior user-scoped Codex target once"

  if rollback_result="$(rollback_control_call "$cid" "$previous_target" "$previous_version")"; then
    if printf '%s' "$rollback_result" | jq -e '.ok == true and .action == "rollback"' >/dev/null 2>&1; then
      record_event "$event_id" rollback "$attempt" restored "$(result_metadata "$rollback_result")"
      if rollback_restart_result="$(control_call "$cid" restart-verify)"; then
        if printf '%s' "$rollback_restart_result" | jq -e '.ok == true and .action == "restart-verify"' >/dev/null 2>&1; then
          record_event "$event_id" rollback_restart "$attempt" verified "$(result_metadata "$rollback_restart_result")"
        else
          record_event "$event_id" rollback_restart "$attempt" failed "$(result_metadata "$rollback_restart_result")"
        fi
      else
        record_event "$event_id" rollback_restart "$attempt" failed "$(result_metadata "$rollback_restart_result")"
      fi
    else
      record_event "$event_id" rollback "$attempt" failed "$(result_metadata "$rollback_result")"
    fi
  else
    record_event "$event_id" rollback "$attempt" failed "$(result_metadata "$rollback_result")"
  fi

  # A daemon restart was attempted.  Do not retry and risk another interruption.
  return 1
}

retry_base_epoch() {
  local now local_day scheduled
  now="$(date +%s)"
  local_day="$(TZ="$timezone" date +%F)"
  scheduled="$(TZ="$timezone" date -d "$local_day $update_time" +%s 2>/dev/null || true)"

  # A timer invocation is anchored to its configured local wall-clock time.
  # A manual diagnostic invocation outside that narrow window retries relative
  # to now, so it remains an immediate maintenance action.
  if printf '%s' "$scheduled" | grep -Eq '^[0-9]+$' && [ "$now" -ge "$scheduled" ] && [ "$((now - scheduled))" -le 120 ]; then
    printf '%s\n' "$scheduled"
  else
    printf '%s\n' "$now"
  fi
}

wait_until_epoch() {
  local deadline="$1"
  local now delay
  now="$(date +%s)"
  if [ "$deadline" -le "$now" ]; then
    log "a technical retry deadline has already passed; retrying immediately"
    return 0
  fi
  delay="$((deadline - now))"
  sleep "$delay"
}

base_epoch="$(retry_base_epoch)"
retry_offsets=(0 300 900 2100)

for index in "$${!retry_offsets[@]}"; do
  attempt="$((index + 1))"
  if [ "$index" -gt 0 ]; then
    wait_until_epoch "$((base_epoch + retry_offsets[index]))"
  fi

  if attempt_update "$attempt"; then
    exit 0
  else
    rc=$?
  fi
  if [ "$rc" -ne 75 ]; then
    exit "$rc"
  fi
  if [ "$index" -lt "$(( $${#retry_offsets[@]} - 1 ))" ]; then
    log "technical pre-restart failure; retaining the next bounded retry slot"
  fi
done

log "technical retries were exhausted before any daemon restart"
exit 1
