#!/usr/bin/env bash
set -euo pipefail

MODE=""
SOURCE=""
TARGET=""
SOURCE_KEY=""
TARGET_KEY=""

usage() {
  cat <<'EOF'
Usage:
  skills/agent-stack-setup/scripts/migrate_provider_data.sh --precopy --source <user@host> --target <user@host> [--source-key <path>] [--target-key <path>]
  skills/agent-stack-setup/scripts/migrate_provider_data.sh --final   --source <user@host> --target <user@host> [--source-key <path>] [--target-key <path>]

Copies the full AgentStack data payload from a source deployment to a fresh
target deployment. --precopy leaves the source running but stops the target
during import. --final stops both stacks before copying and starts only the
target stack after import. The script never destroys cloud infrastructure.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --precopy)
      MODE="precopy"
      shift
      ;;
    --final)
      MODE="final"
      shift
      ;;
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --source-key)
      SOURCE_KEY="${2:-}"
      shift 2
      ;;
    --target-key)
      TARGET_KEY="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$MODE" == "precopy" || "$MODE" == "final" ]] || fail "choose exactly one of --precopy or --final"
[[ -n "$SOURCE" ]] || fail "--source is required"
[[ -n "$TARGET" ]] || fail "--target is required"

source_ssh=(ssh -o IdentitiesOnly=yes -o ConnectTimeout=10)
target_ssh=(ssh -o IdentitiesOnly=yes -o ConnectTimeout=10)
if [[ -n "$SOURCE_KEY" ]]; then
  source_ssh+=(-i "$SOURCE_KEY")
fi
if [[ -n "$TARGET_KEY" ]]; then
  target_ssh+=(-i "$TARGET_KEY")
fi
source_ssh+=("$SOURCE")
target_ssh+=("$TARGET")

run_source() {
  "${source_ssh[@]}" sudo bash -lc "$1"
}

run_target() {
  "${target_ssh[@]}" sudo bash -lc "$1"
}

detect_source_root() {
  run_source 'if [ -d /opt/agent-stack/data ]; then printf %s /opt/agent-stack/data; elif [ -d /opt/openclaw/data ]; then printf %s /opt/openclaw/data; else exit 44; fi' \
    || fail "source has neither /opt/agent-stack/data nor /opt/openclaw/data"
}

stop_stack() {
  local side="$1"
  if [[ "$side" == "source" ]]; then
    run_source 'systemctl stop agent-stack 2>/dev/null || systemctl stop openclaw 2>/dev/null || true'
  else
    run_target 'systemctl stop agent-stack 2>/dev/null || systemctl stop openclaw 2>/dev/null || true'
  fi
}

start_target_stack() {
  run_target 'systemctl start agent-stack 2>/dev/null || systemctl start openclaw'
}

prepare_target() {
  run_target 'install -d -m 0755 /opt/agent-stack /opt/agent-stack/.migration-incoming /opt/agent-stack/data; find /opt/agent-stack/.migration-incoming -mindepth 1 -maxdepth 1 -exec rm -rf {} +'
}

import_on_target() {
  run_target '
set -euo pipefail
incoming=/opt/agent-stack/.migration-incoming/data
target=/opt/agent-stack/data

[ -d "$incoming" ] || { echo "incoming data tree missing" >&2; exit 45; }
install -d -m 0755 "$target"
find "$target" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +

move_children() {
  src="$1"
  dest="$2"
  [ -d "$src" ] || return 0
  install -d -m 0755 "$dest"
  shopt -s dotglob nullglob
  for child in "$src"/*; do
    base="$(basename "$child")"
    [ "$base" = "lost+found" ] && continue
    mv "$child" "$dest/"
  done
  shopt -u dotglob nullglob
  rmdir "$src" 2>/dev/null || true
}

if [ -f "$incoming/.agent-stack-layout-version" ] || [ -d "$incoming/openclaw" ]; then
  move_children "$incoming" "$target"
else
  install -d -m 0755 "$target/openclaw" "$target/hermes" "$target/n8n" "$target/postgres" "$target/caddy/data" "$target/caddy/config"
  move_children "$incoming/services/hermes" "$target/hermes"
  move_children "$incoming/services/n8n" "$target/n8n"
  move_children "$incoming/services/postgres" "$target/postgres"
  move_children "$incoming/services/caddy" "$target/caddy"
  rmdir "$incoming/services" 2>/dev/null || true
  shopt -s dotglob nullglob
  for child in "$incoming"/*; do
    base="$(basename "$child")"
    case "$base" in
      lost+found)
        continue
        ;;
    esac
    mv "$child" "$target/openclaw/"
  done
  shopt -u dotglob nullglob
fi

if [ -x /usr/local/bin/agent-stack-migrate-layout ]; then
  /usr/local/bin/agent-stack-migrate-layout
fi
find /opt/agent-stack/.migration-incoming -mindepth 1 -maxdepth 1 -exec rm -rf {} +
'
}

copy_data() {
  local source_root="$1"
  local source_parent
  local source_base
  source_parent="$(dirname "$source_root")"
  source_base="$(basename "$source_root")"

  "${source_ssh[@]}" sudo tar --numeric-owner -C "$source_parent" -cpf - "$source_base" \
    | "${target_ssh[@]}" sudo tar --numeric-owner -C /opt/agent-stack/.migration-incoming -xpf -
}

SOURCE_ROOT="$(detect_source_root)"

if [[ "$MODE" == "final" ]]; then
  echo "[migration] stopping source and target stacks"
  stop_stack source
  stop_stack target
else
  echo "[migration] stopping target stack for import"
  stop_stack target
fi

echo "[migration] preparing target staging area"
prepare_target
echo "[migration] copying $SOURCE_ROOT to target"
copy_data "$SOURCE_ROOT"
echo "[migration] importing data into /opt/agent-stack/data on target"
import_on_target

echo "[migration] starting target stack"
start_target_stack

echo "[migration] complete"
