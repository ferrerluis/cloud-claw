#!/usr/bin/env python3

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Callable


REPO_ROOT = Path(__file__).resolve().parents[3]
TEMPLATE = REPO_ROOT / "modules/common/templates/cloud_init.yaml.tpl"


class CloudInitTemplateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.template = TEMPLATE.read_text(encoding="utf-8")

    def test_includes_stack_services_and_private_ports(self) -> None:
        self.assertIn("openclaw:", self.template)
        self.assertIn("hermes:", self.template)
        self.assertIn("n8n:", self.template)
        self.assertIn("postgres:", self.template)
        self.assertIn("caddy:", self.template)
        self.assertIn('"127.0.0.1:18789:18789"', self.template)
        self.assertIn('"127.0.0.1:9119:9119"', self.template)
        self.assertIn('"127.0.0.1:5678:5678"', self.template)

    def test_mounts_service_data_under_neutral_peer_paths(self) -> None:
        self.assertIn("/opt/agent-stack/data/openclaw:/home/node/.openclaw", self.template)
        self.assertIn("/opt/agent-stack/data/hermes:/opt/data", self.template)
        self.assertIn("/opt/agent-stack/data/n8n:/home/node/.n8n", self.template)
        self.assertIn("/opt/agent-stack/data/postgres:/var/lib/postgresql/data", self.template)
        self.assertIn("/opt/agent-stack/data/caddy/data:/data", self.template)
        self.assertNotIn("/opt/agent-stack/data/services/hermes:/opt/data", self.template)

    def test_caddy_protects_ui_and_allows_webhooks(self) -> None:
        self.assertIn("basic_auth", self.template)
        self.assertIn("__UI_AUTH_HASH__", self.template)
        self.assertIn("@n8n_webhooks path /webhook* /webhook-test*", self.template)

    def test_hetzner_volume_path_is_supported(self) -> None:
        self.assertIn("provider_type == \"hetzner\"", self.template)
        self.assertIn("/dev/disk/by-id/scsi-0HC_Volume_$VOLUME_ID", self.template)

    def test_systemd_uses_agent_stack_with_openclaw_compatibility(self) -> None:
        self.assertIn("/etc/systemd/system/agent-stack.service", self.template)
        self.assertIn("/etc/systemd/system/openclaw.service", self.template)
        self.assertIn("ExecStart=/bin/systemctl start agent-stack.service", self.template)

    def test_layout_migrator_is_rendered(self) -> None:
        self.assertIn("/usr/local/bin/agent-stack-migrate-layout", self.template)
        self.assertIn("Migrating legacy /opt/openclaw/data payload into peer service layout.", self.template)


class LayoutMigratorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.template = TEMPLATE.read_text(encoding="utf-8")
        cls.script = cls.extract_script(cls.template, "/usr/local/bin/agent-stack-migrate-layout")

    @staticmethod
    def extract_script(template: str, path: str) -> str:
        lines = template.splitlines()
        path_line = f"  - path: {path}"
        start = lines.index(path_line)
        content_index = next(index for index in range(start, len(lines)) if lines[index].strip() == "content: |")
        collected: list[str] = []
        for line in lines[content_index + 1 :]:
            if line.startswith("  - path: "):
                break
            if line.startswith("      "):
                collected.append(line[6:])
            else:
                collected.append(line)
        return ("\n".join(collected) + "\n").replace("$${", "${")

    def run_migrator(self, data_setup: Callable[[Path], None]) -> Path:
        temp_path = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_path)
        app_root = temp_path / "agent-stack"
        data_root = app_root / "data"
        legacy_root = temp_path / "openclaw"
        data_root.mkdir(parents=True)
        data_setup(data_root)
        script_path = temp_path / "agent-stack-migrate-layout"
        script_path.write_text(self.script, encoding="utf-8")
        script_path.chmod(0o755)

        env = dict(os.environ)
        env["AGENT_STACK_APP_ROOT"] = str(app_root)
        env["AGENT_STACK_DATA_ROOT"] = str(data_root)
        env["AGENT_STACK_LEGACY_ROOT"] = str(legacy_root)
        subprocess.run(["bash", str(script_path)], check=True, env=env, capture_output=True, text=True)
        return app_root

    def test_fresh_layout_creates_peer_dirs(self) -> None:
        snapshot = self.run_migrator(lambda _data_root: None)
        data_root = snapshot / "data"
        for name in ["openclaw", "hermes", "n8n", "postgres", "caddy"]:
            self.assertTrue((data_root / name).exists(), name)
        self.assertTrue((data_root / ".agent-stack-layout-version").exists())

    def test_old_openclaw_only_layout_moves_into_openclaw_peer(self) -> None:
        def setup(data_root: Path) -> None:
            (data_root / "openclaw.json").write_text("{}", encoding="utf-8")
            (data_root / "workspace").mkdir()
            (data_root / "workspace" / "SOUL.md").write_text("soul", encoding="utf-8")

        snapshot = self.run_migrator(setup)
        data_root = snapshot / "data"
        self.assertTrue((data_root / "openclaw" / "openclaw.json").exists())
        self.assertTrue((data_root / "openclaw" / "workspace" / "SOUL.md").exists())
        self.assertTrue((data_root / "workspace").is_symlink())

    def test_old_mixed_layout_moves_peer_services(self) -> None:
        def setup(data_root: Path) -> None:
            (data_root / "openclaw.json").write_text("{}", encoding="utf-8")
            (data_root / "services" / "hermes").mkdir(parents=True)
            (data_root / "services" / "hermes" / "session.json").write_text("{}", encoding="utf-8")
            (data_root / "services" / "postgres").mkdir(parents=True)
            (data_root / "services" / "postgres" / "PG_VERSION").write_text("17", encoding="utf-8")

        snapshot = self.run_migrator(setup)
        data_root = snapshot / "data"
        self.assertTrue((data_root / "openclaw" / "openclaw.json").exists())
        self.assertTrue((data_root / "hermes" / "session.json").exists())
        self.assertTrue((data_root / "postgres" / "PG_VERSION").exists())


if __name__ == "__main__":
    unittest.main()
