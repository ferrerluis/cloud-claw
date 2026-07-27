#!/usr/bin/env python3

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
MAIN_TF = REPO_ROOT / "main.tf"
VARIABLES_TF = REPO_ROOT / "variables.tf"


def extract_named_block(source: str, block_type: str, name: str) -> str:
    marker = f'{block_type} "{name}"'
    start = source.index(marker)
    brace_start = source.index("{", start)
    depth = 0
    for index in range(brace_start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace_start + 1 : index]
    raise ValueError(f"unterminated {marker} block")


def top_level_assignments(block: str) -> set[str]:
    names: set[str] = set()
    depth = 0
    for line in block.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if depth == 0:
            match = re.match(r"([A-Za-z0-9_]+)\s*=", stripped)
            if match:
                names.add(match.group(1))
        depth += stripped.count("{") - stripped.count("}")
    return names


def variable_default(source: str, name: str) -> str:
    block = extract_named_block(source, "variable", name)
    match = re.search(r"(?m)^\s*default\s*=\s*(.+)$", block)
    if not match:
        raise AssertionError(f"variable {name} has no default")
    return match.group(1).strip()


class TerraformContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.main_tf = MAIN_TF.read_text(encoding="utf-8")
        cls.variables_tf = VARIABLES_TF.read_text(encoding="utf-8")

    def test_provider_modules_receive_same_shared_runtime_inputs(self) -> None:
        module_args = {
            name: top_level_assignments(extract_named_block(self.main_tf, "module", name))
            for name in ["aws", "digitalocean", "hetzner"]
        }
        provider_specific_prefixes = ("aws_", "do_", "hcloud_")
        provider_specific_names = {
            "source",
            "count",
            "do_existing_volume_name",
        }

        shared_args = {
            name: {
                arg
                for arg in args
                if not arg.startswith(provider_specific_prefixes)
                and arg not in provider_specific_names
            }
            for name, args in module_args.items()
        }

        self.assertEqual(shared_args["aws"], shared_args["digitalocean"])
        self.assertEqual(shared_args["aws"], shared_args["hetzner"])

    def test_agent_stack_defaults_stay_authoritative_in_variables_tf(self) -> None:
        self.assertEqual(variable_default(self.variables_tf, "project_name"), '"agent-stack"')
        self.assertEqual(variable_default(self.variables_tf, "admin_password"), '""')
        self.assertEqual(variable_default(self.variables_tf, "admin_password_ssh_scope"), '"disabled"')
        self.assertEqual(variable_default(self.variables_tf, "host_codex_cli_enabled"), "true")
        self.assertEqual(variable_default(self.variables_tf, "repo_ssh_host_alias"), '"agent-stack"')
        self.assertEqual(
            variable_default(self.variables_tf, "repo_ssh_private_key_path"),
            '".ssh/id_ed25519_agent_stack"',
        )
        self.assertEqual(variable_default(self.variables_tf, "openclaw_health_retries"), "8")
        self.assertEqual(variable_default(self.variables_tf, "openai_auth_mode"), '"api_key"')
        self.assertEqual(variable_default(self.variables_tf, "postgres_image"), '"postgres:17-alpine"')
        self.assertEqual(variable_default(self.variables_tf, "workspace_username"), '"user"')
        self.assertEqual(variable_default(self.variables_tf, "workspace_ssh_host_port"), "2222")
        self.assertEqual(variable_default(self.variables_tf, "workspace_ssh_public_keys"), "[]")
        self.assertEqual(variable_default(self.variables_tf, "workspace_drive_fuse_enabled"), "false")
        self.assertEqual(variable_default(self.variables_tf, "workspace_drive_remote"), '"workspace-drive:"')
        self.assertEqual(variable_default(self.variables_tf, "workspace_drive_vfs_cache_max_size"), '"10G"')
        self.assertEqual(variable_default(self.variables_tf, "vpn_enabled"), "false")
        self.assertEqual(variable_default(self.variables_tf, "vpn_provider"), '"nordvpn_openvpn"')
        self.assertEqual(variable_default(self.variables_tf, "vpn_bypass_cidrs"), "[]")
        self.assertEqual(variable_default(self.variables_tf, "vpn_disable_ipv6"), "true")
        self.assertEqual(variable_default(self.variables_tf, "tailscale_mode"), '"sidecar"')

    def test_admin_password_contract_is_disabled_by_default_and_sensitive(self) -> None:
        admin_password = extract_named_block(self.variables_tf, "variable", "admin_password")
        admin_password_ssh_scope = extract_named_block(self.variables_tf, "variable", "admin_password_ssh_scope")
        self.assertIn("sensitive   = true", admin_password)
        self.assertIn("at least 14 characters", admin_password)
        self.assertIn("disabled", admin_password_ssh_scope)
        self.assertIn("tailnet", admin_password_ssh_scope)
        self.assertIn("public", admin_password_ssh_scope)
        self.assertIn("0.0.0.0/0", admin_password_ssh_scope)

    def test_workspace_contract_is_optional_and_sensitive(self) -> None:
        enabled_services = extract_named_block(self.variables_tf, "variable", "enabled_services")
        workspace_password = extract_named_block(self.variables_tf, "variable", "workspace_password")
        workspace_ssh_public_keys = extract_named_block(self.variables_tf, "variable", "workspace_ssh_public_keys")
        self.assertIn('"workspace"', enabled_services)
        self.assertIn("workspace_password must be set when enabled_services includes workspace.", workspace_password)
        self.assertIn("sensitive   = true", workspace_password)
        self.assertIn("must be OpenSSH public key strings", workspace_ssh_public_keys)
        self.assertNotIn("sensitive   = true", workspace_ssh_public_keys)

        drive_enabled = extract_named_block(self.variables_tf, "variable", "workspace_drive_fuse_enabled")
        drive_config = extract_named_block(self.variables_tf, "variable", "workspace_drive_rclone_config_base64")
        self.assertIn("requires enabled_services to include workspace", drive_enabled)
        self.assertIn("sensitive   = true", drive_config)
        self.assertIn("base64decode", drive_config)

    def test_host_vpn_contract_is_disabled_by_default_and_sensitive(self) -> None:
        vpn_enabled = extract_named_block(self.variables_tf, "variable", "vpn_enabled")
        vpn_provider = extract_named_block(self.variables_tf, "variable", "vpn_provider")
        vpn_username = extract_named_block(self.variables_tf, "variable", "vpn_username")
        vpn_password = extract_named_block(self.variables_tf, "variable", "vpn_password")
        vpn_bypass_cidrs = extract_named_block(self.variables_tf, "variable", "vpn_bypass_cidrs")
        self.assertIn("default     = false", vpn_enabled)
        self.assertIn("nordvpn_openvpn", vpn_provider)
        self.assertIn("sensitive   = true", vpn_username)
        self.assertIn("sensitive   = true", vpn_password)
        self.assertIn("at least one access CIDR", vpn_bypass_cidrs)
        self.assertIn("IPv4 CIDRs", vpn_bypass_cidrs)


if __name__ == "__main__":
    unittest.main()
