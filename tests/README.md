# AgentStack Offline Tests

This directory contains tests that must not create, mutate, or delete cloud
resources.

The canonical command is:

```bash
scripts/test_offline.sh
```

Terraform `>= 1.14` is required for the mocked provider test suite.

Offline health is defined by this command passing. It validates Terraform
formatting and static validity, mocked provider/config combinations, rendered
runtime contracts, migration and doctor script contracts, shell syntax, and
deterministic skill eval lint.

Rules:

- Terraform tests use `terraform test` with mocked providers.
- Test variables must set `ssh_public_key` and `generate_repo_ssh_config = false`
  unless the case is specifically about SSH config generation.
- Do not run `terraform apply`, `terraform destroy`, provider CLIs, or SSH to real
  hosts from tests.
- Skill eval lint is local and deterministic. LLM judging is optional and must be
  run explicitly with credentials.
- If an optional LLM judge run is needed, run `python3 skills/evals/run_eval.py
  judge --transcripts <dir>` with `OPENAI_API_KEY` set. Missing judge credentials
  must not make the offline suite fail.

Subagents should treat this suite as the stopping condition for offline repo
health work: run the command, inspect failures, make the smallest targeted fix,
and stop only when the command passes or a real product decision is required.
