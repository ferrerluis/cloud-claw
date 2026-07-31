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
        self.assertIn('section "VPN health"', script)
        self.assertIn("agent-stack-diagnostics health vpn", script)
        self.assertIn('section "VPN inspect"', script)
        self.assertIn("agent-stack-diagnostics inspect vpn", script)
        self.assertIn('section "VPN logs"', script)
        self.assertIn("agent-stack-diagnostics logs vpn", script)
        self.assertIn('section "Workspace Codex updater"', script)
        self.assertIn("agent-stack-diagnostics codex-update status", script)
        self.assertIn("agent_stack_root=present", script)
        self.assertIn("legacy_root=symlink", script)
        self.assertIn("layout_marker=present", script)

    def test_remote_health_preserves_remote_shell_quoting(self) -> None:
        script = CHECK_REMOTE.read_text(encoding="utf-8")
        self.assertIn('printf -v quoted_command "%q" "$1"', script)
        self.assertIn('"$SSH_WRAPPER" -- "sh -lc $quoted_command"', script)

    def test_collect_diagnostics_checks_agent_stack_ssh_assets(self) -> None:
        script = COLLECT.read_text(encoding="utf-8")
        self.assertIn("bin/agent-stack-ssh", script)
        self.assertIn(".ssh/id_ed25519_agent_stack", script)
        self.assertIn("vpn_note", script)
        self.assertIn("vpn_nordvpn_token", script)
        self.assertIn("<redacted>", script)


if __name__ == "__main__":
    unittest.main()
