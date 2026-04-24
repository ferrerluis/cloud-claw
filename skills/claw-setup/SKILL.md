---
name: claw-setup
description: Guided setup and deployment workflow for this cloud-claw Terraform repo. Use when a user wants help setting up cloud-claw, needs terraform.tfvars created or updated, wants Terraform init or apply run, or needs deployment-time troubleshooting.
---

# Claw Setup

Use this skill for first-time setup, reconfiguration, or guided redeploys.

Core rules:
- Treat `variables.tf` as the schema and true-default source of truth.
- Treat `terraform.tfvars.example` as a suggestion source only for required values that have no Terraform default and for human-friendly examples.
- The target file is `terraform.tfvars` in the repo root. In this workspace it is `/Users/ferrerluis/Documents/GitHub/cloud-claw/terraform.tfvars`.
- Never silently accept placeholder secrets such as `YOUR_AWS_ACCESS_KEY_ID`, `sk-...`, or `tskey-auth-...`.
- Prefer a default-first setup flow. Do not ask one question per Terraform variable when the repo already has a sensible default.
- Keep the normal setup interview to 8 prompts or fewer. Only ask follow-up questions when the user rejects a default, a required value is missing, or the repo has a known limitation.
- Ask grouped decision prompts instead of scalar variable prompts. Collect related values together when that reduces back-and-forth.
- For each high-level prompt, prefer 2-3 clear choices and a custom path when that speeds up intake. Put the recommended option first.
- Ask how the chosen cloud provider will authenticate before moving on. Either collect the provider credentials now or confirm the user already has env or role based auth in place.
- Ask which model providers and channel the user wants before asking for provider-specific secrets.
- If a cloud resource can be resolved from a human-friendly identifier, such as a DigitalOcean volume name, resolve it with a repo-local helper instead of bouncing the lookup back to them.
- Treat `anthropic_auth_key` as a legacy fallback, not the normal Anthropic path. Prefer `anthropic_api_key`.
- If the user wants `openai-codex/*` models, do not ask for a raw refresh token. Prefer importing a local Codex CLI login from `~/.codex/auth.json` after the user runs `codex login` with the ChatGPT sign-in path.

## Workflow

1. Inspect the repo before asking questions.
   - Read `variables.tf`, `main.tf`, and the current `terraform.tfvars` if it exists.
   - Read `terraform.tfvars.example` only for suggestion values and example copy.
   - Run `python3 skills/claw-setup/scripts/render_tfvars.py inspect --repo-root .` to capture the current schema, defaults, and example-backed suggestions.

2. Gather answers with a condensed decision flow.
   - Use `references/question-groups.md` for the canonical prompt order and follow-up rules.
   - Ask provider-specific questions only for the chosen provider.
   - Accept Terraform defaults silently unless the user asks to override them or the field is required and has no default.
   - Do not ask advanced runtime questions unless the user opts into advanced overrides.
   - When the user wants to reuse a DigitalOcean volume by name, resolve it with `python3 skills/claw-setup/scripts/resolve_do_volume.py --name <volume-name>` once a token is available.

3. Write `terraform.tfvars` canonically.
   - Save answers to a temporary JSON file.
   - If `terraform.tfvars` already exists and the user is updating or redeploying, merge the new answers on top of the existing file with `python3 skills/claw-setup/scripts/render_tfvars.py render --repo-root . --answers <answers.json> --base terraform.tfvars --output terraform.tfvars`.
   - If this is a first-time setup, run `python3 skills/claw-setup/scripts/render_tfvars.py render --repo-root . --answers <answers.json> --output terraform.tfvars`.
   - If the renderer rejects placeholders or missing required values, fix the answers before continuing.
   - Leave defaulted variables out of the answers payload unless the user explicitly changed them.

4. Run Terraform with one approval gate.
   - Run `terraform init`.
   - Run `terraform plan` and summarize the outcome.
   - Ask once before `terraform apply`.
   - If apply fails or bootstrap is unhealthy, use `references/verification.md` for targeted recovery and switch to `skills/claw-doctor/SKILL.md` when the issue is no longer setup-specific.

5. Finish with the operator handoff.
   - Surface the important Terraform outputs: `provider_used`, `instance_public_ip`, `ssh_command`, `repo_ssh_command`, `tailscale_note`, `dashboard_url`, `dashboard_url_with_token_import`, `bootstrap_log_command`, `repo_bootstrap_log_command`, `pair_latest_command`, and `whatsapp_login_command`.
   - Call out any deferred manual step such as Tailscale login, Telegram setup, or WhatsApp QR login.

## References

- `references/question-groups.md` for the condensed prompt order and conditional follow-up rules.
- `references/placeholders.md` for placeholder rejection and example-suggestion handling.
- `references/auth-and-schema-gaps.md` for current Anthropic and OpenAI auth guidance, Codex login import steps, and remaining implementation gaps.
- `references/verification.md` for post-apply verification, bootstrap recovery, and handoff commands.
