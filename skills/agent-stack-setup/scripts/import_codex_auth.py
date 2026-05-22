#!/usr/bin/env python3
"""Encode a local Codex auth.json file for terraform.tfvars import."""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path


def fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Base64-encode a Codex auth.json file for openai_codex_auth_json_base64."
    )
    parser.add_argument(
        "--source",
        default=str(Path.home() / ".codex" / "auth.json"),
        help="Path to the Codex auth.json file (default: ~/.codex/auth.json).",
    )
    parser.add_argument(
        "--inspect",
        action="store_true",
        help="Print a short JSON summary instead of the base64 payload.",
    )
    args = parser.parse_args()

    source = Path(args.source).expanduser()
    if not source.exists():
        return fail(f"{source} does not exist; run `codex login` first")

    raw = source.read_bytes()
    try:
        payload = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        return fail(f"{source} is not valid JSON: {exc}")

    if not isinstance(payload, dict):
        return fail(f"{source} must contain a JSON object")

    tokens = payload.get("tokens")
    if not isinstance(tokens, dict) or not tokens.get("refresh_token"):
        return fail(
            f"{source} does not look like a ChatGPT-backed Codex login with tokens.refresh_token; "
            "run `codex login` and choose ChatGPT sign-in, or use openai/* models with openai_api_key instead"
        )

    if args.inspect:
        summary = {
            "source": str(source),
            "auth_mode": payload.get("auth_mode"),
            "has_openai_api_key": bool(payload.get("OPENAI_API_KEY")),
            "has_refresh_token": bool(tokens.get("refresh_token")),
        }
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0

    print(base64.b64encode(raw).decode("ascii"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
