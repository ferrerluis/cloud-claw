#!/usr/bin/env bash
set -euo pipefail

original="$${SSH_ORIGINAL_COMMAND:-status}"

if ! printf '%s' "$original" | grep -Eq '^[A-Za-z0-9_./ -]+$'; then
  echo "unsupported diagnostic command" >&2
  exit 64
fi

# shellcheck disable=SC2086
set -- $original
exec sudo -n /usr/local/bin/agent-stack-diagnostics "$@"
