#!/usr/bin/env python3

from __future__ import annotations

import base64
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "skills/agent-stack-setup/scripts/import_codex_auth.py"


def run_import(source_payload: dict[str, object], *extra_args: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temp_dir:
        source_path = Path(temp_dir) / "auth.json"
        source_path.write_text(json.dumps(source_payload), encoding="utf-8")
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--source",
                str(source_path),
                *extra_args,
            ],
            check=False,
            capture_output=True,
            text=True,
        )


class ImportCodexAuthTest(unittest.TestCase):
    def test_inspect_reports_oauth_login(self) -> None:
        result = run_import(
            {
                "auth_mode": "chatgpt",
                "tokens": {"refresh_token": "refresh", "access_token": "access"},
            },
            "--inspect",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["has_refresh_token"])
        self.assertEqual(payload["auth_mode"], "chatgpt")

    def test_outputs_base64_payload(self) -> None:
        source_payload = {
            "auth_mode": "chatgpt",
            "tokens": {"refresh_token": "refresh", "access_token": "access"},
        }
        result = run_import(source_payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        decoded = json.loads(base64.b64decode(result.stdout.strip()).decode("utf-8"))
        self.assertEqual(decoded, source_payload)

    def test_rejects_api_key_only_auth(self) -> None:
        result = run_import({"auth_mode": "api_key", "OPENAI_API_KEY": "sk-real"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ChatGPT-backed Codex login", result.stderr)


if __name__ == "__main__":
    unittest.main()
