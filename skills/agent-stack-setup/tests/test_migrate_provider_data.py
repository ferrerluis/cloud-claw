#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "skills/agent-stack-setup/scripts/migrate_provider_data.sh"


class ProviderMigrationScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT.read_text(encoding="utf-8")

    def test_help_documents_precopy_and_final_modes(self) -> None:
        result = subprocess.run([str(SCRIPT), "--help"], check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--precopy", result.stdout)
        self.assertIn("--final", result.stdout)
        self.assertIn("--source <user@host>", result.stdout)
        self.assertIn("--target <user@host>", result.stdout)

    def test_final_stops_both_stacks_and_starts_only_target(self) -> None:
        self.assertIn("stop_stack source", self.script)
        self.assertIn("stop_stack target", self.script)
        self.assertIn("start_target_stack", self.script)
        self.assertNotIn("start_source_stack", self.script)

    def test_copy_preserves_numeric_owners_and_never_destroys_infra(self) -> None:
        self.assertIn("tar --numeric-owner", self.script)
        self.assertNotIn("terraform destroy", self.script)

    def test_supports_legacy_and_agent_stack_source_roots(self) -> None:
        self.assertIn("/opt/agent-stack/data", self.script)
        self.assertIn("/opt/openclaw/data", self.script)
        self.assertIn("incoming/services/postgres", self.script)
        self.assertIn("target=/opt/agent-stack/data", self.script)


if __name__ == "__main__":
    unittest.main()
