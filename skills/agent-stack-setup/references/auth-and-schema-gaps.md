# Auth Guidance And Remaining Gaps

Use this note when the setup conversation reaches provider credentials.

## Anthropic

- For AgentStack, the normal Anthropic path should be `anthropic_api_key`.
- Anthropic's API docs say API requests authenticate with an API key in the `x-api-key` header.
- Anthropic's Claude Code docs also support interactive account login inside Claude Code itself, but they do not document a "copy this auth token into a third-party app" setup flow for external tools.
- Anthropic's support docs say that if `ANTHROPIC_API_KEY` is set, Claude Code prioritizes that API key over subscription login.

Recommended setup behavior:

- Treat `anthropic_api_key` as the supported Anthropic credential for this repo.
- Treat `anthropic_auth_key` as a legacy fallback only. Do not ask for it in the normal flow.
- If a user explicitly asks why Anthropic is API-key-first here, explain that this repo is automating a headless third-party deployment, and the documented stable Anthropic integration path for that case is API-key auth.

Implementation note:

- Bootstrap now accepts `ANTHROPIC_API_KEY` for Anthropic model routing.
- The old `anthropic_auth_key` path remains only as an optional legacy fallback for users who already have it.

## OpenAI

- OpenAI supports two distinct routes that matter here:
  - `openai/*` models use `openai_api_key` and bill through the OpenAI API.
- `openai/*` models can use either direct OpenAI API-key auth or Codex login based on `openai_auth_mode`.
- Legacy `openai-codex/*` model refs use a Codex login and subscription-backed OAuth state.
- OpenAI's API reference says the API authenticates with API keys.
- OpenAI's Codex CLI docs say the first Codex run prompts for sign-in with a ChatGPT account or an API key.
- OpenAI's ChatGPT sign-in docs say `codex login` stores credentials locally and creates a key automatically.
- OpenClaw's provider docs support Codex subscription auth and say OpenClaw can reuse an existing Codex CLI login; on current OpenClaw releases this uses canonical `openai/*` refs plus Codex runtime routing.

Recommended setup behavior:

- If the user picks `openai/*` models with `openai_auth_mode = "api_key"`, ask for `openai_api_key`.
- If the user picks `openai/*` models with `openai_auth_mode = "codex"` or legacy `openai-codex/*` models, do not ask for a raw refresh token by default.
- For this repo's import path, support only the ChatGPT-backed Codex login shape that includes `tokens.refresh_token`.
- Instead:
  1. Ask whether the user wants to use their local Codex CLI login for this cloud deployment.
  2. Before inspecting anything, explain that import reads `~/.codex/auth.json` and stores a base64 auth payload in `terraform.tfvars`.
  3. Explain that this value may later appear in Terraform-managed state or cloud-init data.
  4. If the user agrees, ask them to run `codex login` if they have not authenticated Codex locally yet.
  5. Tell them to choose the ChatGPT sign-in path, not API-key login, for subscription-backed Codex auth.
  6. Verify the login is importable with `python3 skills/agent-stack-setup/scripts/import_codex_auth.py --inspect`.
  7. Store the base64 output from `python3 skills/agent-stack-setup/scripts/import_codex_auth.py` in `openai_codex_auth_json_base64`.
  8. If the user does not agree, offer three safe alternatives: paste an already-exported `openai_codex_auth_json_base64`, switch to `openai/*` API-key models, or defer model auth until later.

Why this is the preferred path:

- OpenAI's public docs do not describe a manual "copy this refresh token out of the browser" workflow.
- The official Codex flow is local login, with credentials stored locally.
- This repo can import that local credential state directly, which is safer and less error-prone than asking the user to paste opaque OAuth tokens.
- Although Codex can also authenticate with an API key, this specific importer supports the ChatGPT-backed Codex login shape only. If the user only wants API-key auth, steer them to `openai_auth_mode = "api_key"`.
- `import_codex_auth.py --inspect` still reads local auth metadata, so it requires the same explicit consent as the full import.

Implementation note:

- Terraform now supports `openai_codex_auth_json_base64`.
- Bootstrap writes that payload to `/opt/agent-stack/codex/auth.json` and mounts it into the OpenClaw container as `/home/node/.codex/auth.json`.
- Renderer validation now requires `openai_codex_auth_json_base64` when `openai_auth_mode = "codex"` with `openai/*` models or when legacy `openai-codex/*` refs are used.
- Because this value is treated like other setup secrets, the skill should remind the user that it will live in `terraform.tfvars` and may also appear in Terraform-managed state or cloud-init data.

## DigitalOcean Volume Reuse

- The DigitalOcean module requires both `do_existing_volume_id` and `do_existing_volume_name` for reuse.
- Users commonly know only the volume name from the UI.

Recommended skill behavior:

- If the user wants to reuse a DigitalOcean volume and has a valid `do_token`, resolve the volume ID from the name via `python3 skills/agent-stack-setup/scripts/resolve_do_volume.py --name <volume-name>`.
- Only ask the user for the raw volume ID if automated lookup is unavailable.

## Low-Value Defaults

These fields should stay on defaults unless the user explicitly asks to override them:

- `repo_ssh_private_key_path`
- `generate_repo_ssh_config`
- `repo_ssh_host_alias`
- `repo_ssh_identity_file`
- `openclaw_config_mode`
- `openclaw_health_start_period_seconds`
- `openclaw_health_retries`
- `openclaw_swap_size_mb`
- `seed_starter_workspace_files`
- `starter_soul_profile`
- `gateway_token`

## Sources

- OpenAI Codex CLI docs: https://developers.openai.com/codex/cli
- OpenAI sign-in flow: https://help.openai.com/en/articles/11381614-codex-codex-andsign-in-with-chatgpt
- OpenAI API authentication: https://developers.openai.com/api/reference/overview#authentication
- Anthropic API getting started: https://docs.anthropic.com/en/api/getting-started
- Anthropic Claude Code auth priority: https://support.claude.com/en/articles/12304248-managing-api-key-environment-variables-in-claude-code
- Anthropic Claude Code quickstart: https://code.claude.com/docs/en/quickstart
- OpenClaw OpenAI provider docs: https://github.com/openclaw/openclaw/blob/main/docs/providers/openai.md
- OpenClaw OAuth concept docs: https://github.com/openclaw/openclaw/blob/main/docs/concepts/oauth.md
