#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

section() {
  printf '\n== %s ==\n' "$1"
}

section "Safety boundary"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
unset DIGITALOCEAN_TOKEN DO_TOKEN HCLOUD_TOKEN
unset TF_VAR_aws_access_key TF_VAR_aws_secret_key TF_VAR_do_token TF_VAR_hcloud_token
echo "Cloud credential environment variables have been unset for this run."

section "Terraform format"
terraform fmt -check -recursive

section "Terraform version"
terraform version -json | python3 -c '
import json
import sys

version = json.load(sys.stdin)["terraform_version"]
parts = tuple(int(part) for part in version.split(".")[:2])
if parts < (1, 14):
    raise SystemExit(f"Terraform >= 1.14 is required for the mocked test suite; found {version}")
print(f"Terraform {version} satisfies mocked test requirement.")
'

section "Terraform init"
if [[ -d .terraform/providers && -f .terraform/modules/modules.json ]]; then
  echo "Terraform is already initialized; reusing local providers and modules."
else
  terraform init -backend=false -input=false
fi

section "Terraform validate"
terraform validate

section "Terraform mocked tests"
terraform test -test-directory=tests/terraform

section "Python tests"
if python3 -m pytest --version >/dev/null 2>&1; then
  python3 -m pytest \
    skills/agent-stack-setup/tests \
    skills/agent-stack-doctor/tests \
    tests
else
  echo "pytest is not installed; falling back to unittest discovery."
  python3 -m unittest discover -s skills/agent-stack-setup/tests -p 'test_*.py'
  python3 -m unittest discover -s skills/agent-stack-doctor/tests -p 'test_*.py'
  python3 -m unittest discover -s tests -p 'test_*.py'
fi

section "Shell syntax"
for script in \
  skills/agent-stack-setup/scripts/migrate_provider_data.sh \
  skills/agent-stack-doctor/scripts/check_remote_health.sh \
  skills/agent-stack-doctor/scripts/collect_diagnostics.sh
do
  bash -n "$script"
done

section "Shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck \
    skills/agent-stack-setup/scripts/migrate_provider_data.sh \
    skills/agent-stack-doctor/scripts/check_remote_health.sh \
    skills/agent-stack-doctor/scripts/collect_diagnostics.sh
else
  echo "shellcheck is not installed; skipped."
fi

section "Skill eval lint"
python3 skills/evals/run_eval.py lint

section "Offline suite complete"
