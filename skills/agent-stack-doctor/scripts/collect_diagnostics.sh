#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SHOW_SECRETS=0

usage() {
  cat <<'EOF'
Usage: skills/agent-stack-doctor/scripts/collect_diagnostics.sh [--show-secrets]

By default, secret-bearing Terraform outputs are redacted.
Use --show-secrets only when you intentionally need the raw values.
EOF
}

section() {
  printf '\n== %s ==\n' "$1"
}

file_status() {
  local path="$1"
  if [[ -e "$path" ]]; then
    printf 'present  %s\n' "$path"
  else
    printf 'missing  %s\n' "$path"
  fi
}

tool_status() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    printf 'present  %s -> %s\n' "$tool" "$(command -v "$tool")"
  else
    printf 'missing  %s\n' "$tool"
  fi
}

redact_output() {
  local name="$1"
  local value="$2"

  if [[ "$SHOW_SECRETS" -eq 1 ]]; then
    printf '%s' "$value"
    return
  fi

  case "$name" in
    gateway_token|ui_auth_password)
      printf '<redacted>'
      return
      ;;
  esac

  if [[ "$value" == *"#token="* ]]; then
    printf '%s' "$value" | sed -E 's/#token=[^[:space:]]+/#token=<redacted>/g'
    return
  fi

  if [[ "$value" == *"--token "* ]]; then
    printf '%s' "$value" | sed -E 's/--token[[:space:]]+[^[:space:]]+/--token <redacted>/g'
    return
  fi

  if [[ "$value" == *"vpn_nordvpn_token"* ]]; then
    printf '%s' "$value" | sed -E 's/(vpn_nordvpn_token[[:space:]]*=[[:space:]]*)("[^"]*"|[^[:space:]]+)/\1<redacted>/g'
    return
  fi

  printf '%s' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-secrets)
      SHOW_SECRETS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

section "Repo"
printf 'root: %s\n' "$ROOT_DIR"

section "Local tools"
for tool in terraform ssh python3 jq; do
  tool_status "$tool"
done

section "Key files"
cd "$ROOT_DIR"
for path in \
  terraform.tfvars \
  terraform.tfvars.example \
  variables.tf \
  outputs.tf \
  bin/agent-stack-ssh \
  bin/agent-stack-ssh-clean \
  .ssh/config \
  .ssh/id_ed25519_agent_stack \
  .ssh/id_ed25519_agent_stack.pub
do
  file_status "$path"
done

section "Terraform outputs"
if command -v terraform >/dev/null 2>&1 && terraform -chdir="$ROOT_DIR" output -json >/dev/null 2>&1; then
  for name in \
    provider_used \
    instance_public_ip \
    ssh_command \
    repo_ssh_command \
    resolved_ssh_public_key_source \
    tailscale_note \
    vpn_note \
    dashboard_url \
    dashboard_url_with_token_import \
    openclaw_url \
    hermes_url \
    n8n_url \
    n8n_webhook_url \
    ui_auth_username \
    ui_auth_password \
    gateway_token \
    pair_latest_command \
    repo_pair_latest_command \
    bootstrap_log_command \
    repo_bootstrap_log_command
  do
    value="$(terraform -chdir="$ROOT_DIR" output -raw "$name" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      printf '%s=%s\n' "$name" "$(redact_output "$name" "$value")"
    else
      printf '%s=<unavailable>\n' "$name"
    fi
  done
else
  echo "terraform outputs unavailable"
fi
