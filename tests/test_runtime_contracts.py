#!/usr/bin/env python3

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CLOUD_INIT = REPO_ROOT / "modules/common/templates/cloud_init.yaml.tpl"
MIGRATION_SCRIPT = REPO_ROOT / "skills/agent-stack-setup/scripts/migrate_provider_data.sh"
CHECK_REMOTE = REPO_ROOT / "skills/agent-stack-doctor/scripts/check_remote_health.sh"
COLLECT_DIAGNOSTICS = REPO_ROOT / "skills/agent-stack-doctor/scripts/collect_diagnostics.sh"
GOLDEN_DIR = REPO_ROOT / "tests/golden/cloud_init"


def golden_lines(name: str) -> list[str]:
    path = GOLDEN_DIR / name
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


class RuntimeContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cloud_init = CLOUD_INIT.read_text(encoding="utf-8")
        cls.migration = MIGRATION_SCRIPT.read_text(encoding="utf-8")
        cls.check_remote = CHECK_REMOTE.read_text(encoding="utf-8")
        cls.collect = COLLECT_DIAGNOSTICS.read_text(encoding="utf-8")

    def test_cloud_init_contains_golden_agentstack_paths(self) -> None:
        for snippet in golden_lines("required_agentstack_snippets.txt"):
            with self.subTest(snippet=snippet):
                self.assertIn(snippet, self.cloud_init)

    def test_cloud_init_rejects_legacy_service_data_roots(self) -> None:
        for snippet in golden_lines("forbidden_legacy_service_snippets.txt"):
            with self.subTest(snippet=snippet):
                self.assertNotIn(snippet, self.cloud_init)

    def test_public_caddy_routes_gate_ui_and_optionally_leave_webhooks_public(self) -> None:
        self.assertIn("basic_auth", self.cloud_init)
        self.assertIn("@n8n_webhooks path /webhook* /webhook-test*", self.cloud_init)
        self.assertRegex(
            self.cloud_init,
            re.compile(r"handle @n8n_webhooks \{\n\s+reverse_proxy n8n:5678", re.MULTILINE),
        )
        self.assertRegex(
            self.cloud_init,
            re.compile(r"handle \{\n\s+import agentstack_ui_auth\n\s+reverse_proxy n8n:5678", re.MULTILINE),
        )

    def test_provider_migration_copies_all_peer_data_and_preserves_owners(self) -> None:
        self.assertIn("/opt/agent-stack/data", self.migration)
        self.assertIn("/opt/openclaw/data", self.migration)
        for service in ["hermes", "n8n", "postgres", "caddy"]:
            with self.subTest(service=service):
                self.assertIn(f'incoming/services/{service}', self.migration)
                self.assertIn(f'target/{service}', self.migration)
        self.assertIn("tar --numeric-owner", self.migration)

    def test_provider_migration_final_stops_both_and_precopy_leaves_source_running(self) -> None:
        self.assertIn('if [[ "$MODE" == "final" ]]', self.migration)
        self.assertIn("stop_stack source", self.migration)
        self.assertIn("stop_stack target", self.migration)
        self.assertIn('echo "[migration] stopping target stack for import"', self.migration)
        self.assertNotIn("start_source_stack", self.migration)

    def test_doctor_scripts_redact_and_report_new_stack_health(self) -> None:
        self.assertIn("gateway_token|ui_auth_password", self.collect)
        self.assertIn("#token=<redacted>", self.collect)
        self.assertIn("--token <redacted>", self.collect)
        for container in ["Hermes", "n8n", "Postgres", "Caddy"]:
            with self.subTest(container=container):
                self.assertIn(f'section "{container}', self.check_remote)

    def test_test_paths_do_not_contain_cloud_mutating_commands(self) -> None:
        test_paths = [
            REPO_ROOT / "scripts/test_offline.sh",
            REPO_ROOT / "tests",
            REPO_ROOT / "skills/evals",
        ]
        banned = [
            "terraform " + "apply",
            "terraform " + "destroy",
            "doctl" + " ",
            "hcloud" + " ",
            "aws " + "ec2",
        ]
        for path in test_paths:
            files = [path] if path.is_file() else [p for p in path.rglob("*") if p.is_file()]
            for file_path in files:
                if "__pycache__" in file_path.parts or file_path.suffix in {".pyc", ".md", ".json", ".txt"}:
                    continue
                if file_path.suffix not in {".sh", ".py", ".hcl"}:
                    continue
                text = file_path.read_text(encoding="utf-8")
                for phrase in banned:
                    with self.subTest(file=str(file_path), phrase=phrase):
                        self.assertNotIn(phrase, text)


if __name__ == "__main__":
    unittest.main()
