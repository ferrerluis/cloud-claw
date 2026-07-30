#!/usr/bin/env python3

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
WATCHDOG = REPO_ROOT / "skills/agent-stack-doctor/scripts/workspace_drive_mount_watchdog.sh"
SHELL_GUARD = REPO_ROOT / "skills/agent-stack-doctor/scripts/workspace_drive_shell_guard.sh"


class WorkspaceDriveWatchdogTest(unittest.TestCase):
    def run_watchdog_bash(
        self,
        body: str,
        *,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["WORKSPACE_DRIVE_SOURCE_ONLY"] = "true"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", "-c", 'source "$1"\n' + body, "bash", str(WATCHDOG)],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_supervised_foreground_contract(self) -> None:
        script = WATCHDOG.read_text(encoding="utf-8")
        guard = SHELL_GUARD.read_text(encoding="utf-8")
        self.assertIn("flock -n 9", script)
        self.assertIn('fusermount3 -uz "$MOUNTPOINT"', script)
        self.assertIn('timeout "$HEALTH_TIMEOUT" stat "$MOUNTPOINT"', script)
        self.assertIn('rclone rc --url "$RC_URL" rc/noop', script)
        self.assertIn('--rc-addr "$RC_ADDR"', script)
        self.assertIn("--update", script)
        self.assertNotIn("--daemon", script)
        self.assertIn("workspace_drive_ensure", guard)
        self.assertIn("workspace_drive_guard", guard)

    def test_expected_mount_requires_exact_source_and_type(self) -> None:
        healthy = self.run_watchdog_bash(
            """
mount_info_at() { printf '/tmp/workspace workspace-drive: fuse.rclone\\n'; }
is_expected_mount_at /tmp/workspace
"""
        )
        self.assertEqual(healthy.returncode, 0, healthy.stderr)

        wrong_source = self.run_watchdog_bash(
            """
mount_info_at() { printf '/tmp/workspace local-disk fuse.rclone\\n'; }
if is_expected_mount_at /tmp/workspace; then exit 1; fi
"""
        )
        self.assertEqual(wrong_source.returncode, 0, wrong_source.stderr)

    def test_stale_or_dead_mount_fails_health(self) -> None:
        stale = self.run_watchdog_bash(
            """
is_expected_mount() { return 0; }
timeout() { return 1; }
if mount_endpoint_healthy; then exit 1; fi
"""
        )
        self.assertEqual(stale.returncode, 0, stale.stderr)

        dead = self.run_watchdog_bash(
            """
is_expected_mount() { return 0; }
timeout() { return 0; }
rclone_pid_for_mount() { printf '999999\\n'; }
kill() { return 1; }
if mount_endpoint_healthy; then exit 1; fi
"""
        )
        self.assertEqual(dead.returncode, 0, dead.stderr)

    def test_guard_requires_supervisor_and_endpoint(self) -> None:
        result = self.run_watchdog_bash(
            """
supervisor_alive() { return 1; }
mount_endpoint_healthy() { return 0; }
if guard; then exit 1; fi
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicate_supervisor_exits_without_starting_mount(self) -> None:
        with tempfile.TemporaryDirectory() as state_dir:
            result = self.run_watchdog_bash(
                """
require_prereqs() { return 0; }
flock() { return 1; }
supervise
""",
                extra_env={"WORKSPACE_DRIVE_STATE_DIR": state_dir},
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("another supervisor already holds", result.stdout)

    def test_mountpoint_residue_is_refused_and_protected(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            mountpoint = Path(parent) / "workspace"
            mountpoint.mkdir()
            (mountpoint / "local-only.txt").write_text("keep me", encoding="utf-8")
            result = self.run_watchdog_bash(
                """
mount_record_exists() { return 1; }
if prepare_mountpoint_for_mount; then exit 1; fi
test "$(stat -c '%a' "$MOUNTPOINT")" = "0"
""",
                extra_env={"WORKSPACE_DRIVE_MOUNTPOINT": str(mountpoint)},
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_recovery_orders_stop_unmount_protect_and_remount(self) -> None:
        with tempfile.TemporaryDirectory() as state_dir:
            trace = Path(state_dir) / "trace"
            result = self.run_watchdog_bash(
                """
log() { :; }
terminate_expected_rclone() { printf 'terminate\\n' >>"$TRACE"; }
clear_expected_mount() { printf 'unmount\\n' >>"$TRACE"; }
protect_unmounted_mountpoint() { printf 'protect\\n' >>"$TRACE"; }
prepare_mountpoint_for_mount() { printf 'prepare\\n' >>"$TRACE"; }
launch_rclone() { printf 'launch\\n' >>"$TRACE"; }
wait_for_mount_ready() { printf 'ready\\n' >>"$TRACE"; return 0; }
attempt_recovery
cat "$TRACE"
""",
                extra_env={"TRACE": str(trace)},
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            ["terminate", "unmount", "protect", "prepare", "launch", "ready"],
        )


if __name__ == "__main__":
    unittest.main()
