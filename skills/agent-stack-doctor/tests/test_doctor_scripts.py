#!/usr/bin/env python3

from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
CHECK_REMOTE = REPO_ROOT / "skills/agent-stack-doctor/scripts/check_remote_health.sh"
COLLECT = REPO_ROOT / "skills/agent-stack-doctor/scripts/collect_diagnostics.sh"


class DoctorScriptsTest(unittest.TestCase):
    def test_remote_health_prefers_agent_stack_and_reports_layout(self) -> None:
        script = CHECK_REMOTE.read_text(encoding="utf-8")
        self.assertIn("systemctl status --no-pager agent-stack", script)
        self.assertIn("systemctl status --no-pager openclaw", script)
        self.assertIn("agent_stack_root=present", script)
        self.assertIn("legacy_root=symlink", script)
        self.assertIn("layout_marker=present", script)

    def test_collect_diagnostics_checks_new_and_legacy_ssh_assets(self) -> None:
        script = COLLECT.read_text(encoding="utf-8")
        self.assertIn("bin/agent-stack-ssh", script)
        self.assertIn("bin/cloud-claw-ssh", script)
        self.assertIn(".ssh/id_ed25519_agent_stack", script)
        self.assertIn(".ssh/id_ed25519_cloud_claw", script)


if __name__ == "__main__":
    unittest.main()
