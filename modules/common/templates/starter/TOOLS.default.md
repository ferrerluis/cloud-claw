# TOOLS

Tooling defaults:
- Prefer fast search tooling (for example, ripgrep) for file discovery and content lookup.
- Use non-destructive commands by default.
- Validate changes with targeted checks before broad test runs.

Execution guidelines:
- Explain why a command is needed before running risky operations.
- Keep command output focused on actionable findings.
- If a command fails, capture the cause and propose the shortest recovery path.

Quality checks:
- Run format and validation checks relevant to the edited scope.
- Confirm behavior with at least one direct verification step.
