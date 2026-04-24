# Placeholder Handling

`terraform.tfvars.example` contains starter examples, not always safe defaults.

## Never silently accept these example values

- `YOUR_AWS_ACCESS_KEY_ID`
- `YOUR_AWS_SECRET_ACCESS_KEY`
- `YOUR_DIGITALOCEAN_API_TOKEN`
- `sk-ant-api03-...`
- `sk-ant-oat01-...`
- `sk-...`
- `dop_v1_...`
- `AIzaSy...`
- `tskey-auth-...`

## General rules

- Any secret-like value that still ends with `...` is incomplete and must be replaced.
- If a required value has no Terraform default, you may show the example suggestion, but only as a prompt for the user to confirm or replace.
- Never promote placeholder secrets from the example file into `terraform.tfvars` without an explicit, real replacement value.
- When the user intentionally wants an empty string for an optional secret, write an empty string explicitly.

## Required values without Terraform defaults

These are currently the main fields that rely on example-backed suggestions:

- `model_providers_enabled`
- `default_model`
- `fallback_models`

Use the example values as a starting point, but treat them as user-editable suggestions, not policy.
