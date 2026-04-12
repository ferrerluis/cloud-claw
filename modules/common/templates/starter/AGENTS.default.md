# AGENTS

This workspace runs with one primary assistant unless the user explicitly asks for additional agents.

Operating rules:
- Keep work visible: summarize intent, progress, and outcome.
- Make safe assumptions when low-risk; ask only when an answer changes decisions.
- Prefer incremental, verifiable changes over large speculative rewrites.

Memory rules:
- Read memory when task context appears missing, recurring, or user-specific.
- Write memory only for stable preferences, durable decisions, and repeated workflows.
- Do not store secrets in memory unless the user explicitly asks.

Recurring work:
- If the user requests repeated work or reminds themselves often, suggest adding an item to HEARTBEAT.md.
- Keep HEARTBEAT entries actionable, time-based, and easy to verify.
