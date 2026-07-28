#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import os
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest
from dataclasses import replace
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[3]
RUNTIME_DIR = REPO_ROOT / "modules/common/templates/runtime"


class WorkspaceCodexAutoUpdateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def template(self, name: str) -> str:
        return (RUNTIME_DIR / name).read_text(encoding="utf-8")

    def render(self, name: str, **values: str) -> Path:
        source = self.template(name).replace("$${", "${")
        defaults = {
            "workspace_username": "workspace",
            "workspace_codex_auto_update_enabled": "true",
            "workspace_codex_auto_update_timezone": "America/New_York",
            "workspace_codex_auto_update_time": "04:00",
            "workspace_codex_auto_recover_interrupted_turns": "false",
            "workspace_fuse_enabled": "false",
            "vpn_enabled": "false",
            "vpn_provider": "nordvpn_openvpn",
            "tailscale_host_enabled": "false",
            "vpn_healthcheck_url": "https://example.invalid",
        }
        defaults.update(values)
        for key, value in defaults.items():
            source = source.replace(f"${{{key}}}", value)
        path = self.root / name.removesuffix(".tpl")
        path.write_text(source, encoding="utf-8")
        path.chmod(0o755)
        return path

    def control_module(self):
        loader = SourceFileLoader(
            "agent_stack_workspace_codex_control_test",
            str(RUNTIME_DIR / "workspace-codex-control.py.tpl"),
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module

    def control_context(self, control, *, current_target: Path | None = None):
        home = (self.root / "workspace-home").resolve()
        release = home / ".codex/packages/standalone/releases/1.2.3"
        standalone = home / ".codex/packages/standalone"
        return control.Context(
            home=home,
            codex_home=home / ".codex",
            standalone=standalone,
            releases=standalone / "releases",
            current=standalone / "current",
            current_target=current_target or release,
            launcher=home / ".local/bin/codex",
            command_bin=home / ".local/bin/codex",
            socket_path=home / ".codex/app-server-control/app-server-control.sock",
            pid_file=home / ".codex/app-server-daemon/app-server.pid",
            updater_pid_file=home / ".codex/app-server-daemon/app-server-updater.pid",
            username="workspace",
            uid=1000,
        )

    def render_worker(self, **values: str) -> tuple[Path, Path]:
        """Render the host worker with its root-only ledger redirected to tmp.

        The worker deliberately insists on uid 0.  The behavioral tests put a
        fixed fake `id` first on PATH, rather than weakening the template just
        to make it testable on a developer laptop.
        """

        worker = self.render("agent-stack-workspace-codex-update.sh.tpl", **values)
        state_dir = self.root / "host-maintenance-state"
        source = worker.read_text(encoding="utf-8").replace(
            "state_dir=/var/lib/agent-stack/workspace-codex-update",
            f"state_dir={shlex.quote(str(state_dir))}",
        )
        worker.write_text(source, encoding="utf-8")
        worker.chmod(0o755)
        return worker, state_dir

    def make_worker_fake_runtime(self, mode: str) -> tuple[Path, Path, Path]:
        """Install fixed-purpose fake host commands for a worker subprocess.

        The docker fake implements only the concrete `compose`, initializer,
        and control-helper calls made by the worker.  It intentionally has no
        escape hatch for arbitrary command execution, mirroring the runtime
        bridge's narrow contract.
        """

        fakebin = self.root / "worker-fakebin"
        fakebin.mkdir()
        log = self.root / "worker-fake.log"
        counter_dir = self.root / "worker-fake-counts"
        counter_dir.mkdir()

        def executable(name: str, source: str) -> None:
            path = fakebin / name
            path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
            path.chmod(0o755)

        executable(
            "id",
            """
            #!/bin/sh
            if [ "${1:-}" = "-u" ]; then
              printf '0\\n'
              exit 0
            fi
            exit 1
            """,
        )
        executable(
            "install",
            """
            #!/bin/sh
            set -eu
            destination=""
            for argument in "$@"; do
              destination="$argument"
            done
            /bin/mkdir -p "$destination"
            """,
        )
        executable(
            "flock",
            """
            #!/bin/sh
            # The behavior under test is retry/rollback, not kernel locking.
            exit 0
            """,
        )
        executable(
            "sleep",
            """
            #!/bin/sh
            printf 'sleep:%s\\n' "${1:-}" >> "$FAKE_LOG"
            """,
        )
        executable(
            "date",
            """
            #!/bin/sh
            for argument in "$@"; do
              case "$argument" in
                +%Y-%m-%dT%H:%M:%SZ)
                  printf '2026-07-23T04:00:00Z\\n'
                  exit 0
                  ;;
                +%Y%m%dT%H%M%SZ)
                  printf '20260723T040000Z\\n'
                  exit 0
                  ;;
                +%F)
                  printf '2026-07-23\\n'
                  exit 0
                  ;;
              esac
            done
            if [ "${1:-}" = "-d" ]; then
              printf '1000\\n'
            else
              printf '1000\\n'
            fi
            """,
        )
        executable(
            "docker",
            """
            #!/bin/sh
            set -eu

            next_count() {
              name="$1"
              file="$FAKE_COUNTER_DIR/$name"
              if [ -f "$file" ]; then
                count=$(/bin/cat "$file")
              else
                count=0
              fi
              count=$((count + 1))
              printf '%s\\n' "$count" > "$file"
              printf '%s\\n' "$count"
            }

            preflight() {
              printf '%s\\n' '{"ok":true,"action":"preflight","version":"1.2.3","current_target":"/home/workspace/.codex/packages/standalone/releases/1.2.3"}'
            }

            snapshot() {
              if [ "$FAKE_MODE" = "recovery_duplicate" ]; then
                printf '%s\\n' '{"ok":true,"action":"snapshot","snapshot":[{"threadId":"thread-1","turnId":"turn-1","recoveryEligible":true},{"threadId":"thread-1","turnId":"turn-1","recoveryEligible":true}]}'
              else
                printf '%s\\n' '{"ok":true,"action":"snapshot","snapshot":[]}'
              fi
            }

            update_no_change() {
              printf '%s\\n' '{"ok":true,"action":"update","before_version":"1.2.3","after_version":"1.2.3","changed":false,"target_changed":false,"previous_target":"/home/workspace/.codex/packages/standalone/releases/1.2.3"}'
            }

            update_changed() {
              printf '%s\\n' '{"ok":true,"action":"update","before_version":"1.2.3","after_version":"1.2.4","changed":true,"target_changed":true,"previous_target":"/home/workspace/.codex/packages/standalone/releases/1.2.3"}'
            }

            if [ "${1:-}" = "compose" ]; then
              printf 'docker:compose\\n' >> "$FAKE_LOG"
              printf 'workspace-test-container\\n'
              exit 0
            fi

            action=""
            for argument in "$@"; do
              if [ "$argument" = "--normalize" ]; then
                printf 'docker:normalize\\n' >> "$FAKE_LOG"
                if [ "$FAKE_MODE" = "canonicalization_failure" ]; then
                  exit 1
                fi
                exit 0
              fi
              action="$argument"
            done
            printf 'docker:%s\\n' "$action" >> "$FAKE_LOG"

            case "$action" in
              preflight)
                preflight_count=$(next_count preflight)
                if [ "$FAKE_MODE" = "retry_slots" ] && [ "$preflight_count" -eq 1 ]; then
                  printf '%s\\n' '{"ok":false,"action":"preflight","error":"socket_unavailable"}'
                  exit 75
                fi
                preflight
                ;;
              snapshot)
                snapshot_count=$(next_count snapshot)
                if [ "$FAKE_MODE" = "retry_slots" ] && [ "$snapshot_count" -le 2 ]; then
                  printf '%s\\n' '{"ok":false,"action":"snapshot","error":"rpc_timeout"}'
                  exit 75
                fi
                snapshot
                ;;
              update)
                case "$FAKE_MODE" in
                  retry_slots|no_update)
                    update_no_change
                    ;;
                  restart_failure|recovery_duplicate)
                    update_changed
                    ;;
                  *)
                    printf '%s\\n' '{"ok":false,"action":"update","error":"unexpected_fake_mode"}'
                    exit 1
                    ;;
                esac
                ;;
              restart-verify)
                restart_count=$(next_count restart)
                if [ "$FAKE_MODE" = "restart_failure" ] && [ "$restart_count" -eq 1 ]; then
                  printf '%s\\n' '{"ok":false,"action":"restart-verify","error":"daemon_verification_failed"}'
                  exit 1
                fi
                printf '%s\\n' '{"ok":true,"action":"restart-verify"}'
                ;;
              rollback)
                printf '%s\\n' '{"ok":true,"action":"rollback"}'
                ;;
              recover)
                printf '%s\\n' '{"recovered":true,"thread_id":"thread-1","turn_id":"recovery-turn"}'
                ;;
              *)
                printf '%s\\n' '{"ok":false,"error":"unexpected_action"}'
                exit 1
                ;;
            esac
            """,
        )
        return fakebin, log, counter_dir

    def run_worker(self, mode: str, **values: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        worker, _state_dir = self.render_worker(**values)
        fakebin, log, counter_dir = self.make_worker_fake_runtime(mode)
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fakebin}:/usr/bin:/bin:/sbin",
                "AGENT_STACK_APP_ROOT": str(self.root / "fake-app"),
                "FAKE_MODE": mode,
                "FAKE_LOG": str(log),
                "FAKE_COUNTER_DIR": str(counter_dir),
            }
        )
        result = subprocess.run(
            [str(worker), "--scheduled"],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
            env=environment,
        )
        entries = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
        return result, entries

    def test_hard_cutover_timer_is_non_catch_up_and_exactly_rendered(self) -> None:
        timer = self.render(
            "agent-stack-workspace-codex-update.timer.tpl",
            workspace_codex_auto_update_timezone="America/New_York",
            workspace_codex_auto_update_time="04:00",
        ).read_text(encoding="utf-8")

        self.assertIn("OnCalendar=*-*-* 04:00:00 America/New_York", timer)
        self.assertIn("Persistent=false", timer)
        self.assertIn("AccuracySec=1s", timer)
        self.assertIn("RandomizedDelaySec=0", timer)
        self.assertNotIn("OnBootSec", timer)
        self.assertNotIn("Persistent=true", timer)

    def test_host_worker_has_only_bounded_pre_restart_retry_slots(self) -> None:
        worker = self.template("agent-stack-workspace-codex-update.sh.tpl")

        self.assertIn("retry_offsets=(0 300 900 2100)", worker)
        self.assertIn("wait_until_epoch", worker)
        self.assertIn("base_epoch + retry_offsets[index]", worker)
        self.assertIn("return 75", worker)
        self.assertIn("A daemon restart was attempted.  Do not retry", worker)
        self.assertIn('control_call "$cid" preflight', worker)
        self.assertIn('if [ "$changed" != "true" ]', worker)
        self.assertIn("Codex is already current; the app-server was not restarted", worker)
        self.assertIn(
            'rollback_control_call "$cid" "$known_previous_target" "$known_previous_version"',
            worker,
        )
        self.assertIn(
            'rollback_control_call "$cid" "$previous_target" "$previous_version"',
            worker,
        )
        self.assertNotIn("pgrep", worker)
        self.assertNotIn("workspace Codex is active", worker)
        self.assertNotIn("while true", worker)

    def test_worker_uses_exact_absolute_retry_slots_for_preflight_and_snapshot_failures(self) -> None:
        result, entries = self.run_worker("retry_slots")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [entry for entry in entries if entry.startswith("sleep:")],
            ["sleep:300", "sleep:900", "sleep:2100"],
        )
        self.assertEqual(entries.count("docker:preflight"), 4)
        self.assertEqual(entries.count("docker:snapshot"), 3)
        self.assertEqual(entries.count("docker:update"), 1)
        self.assertNotIn("docker:restart-verify", entries)
        self.assertNotIn("docker:rollback", entries)

    def test_worker_skips_daemon_restart_when_codex_is_already_current(self) -> None:
        result, entries = self.run_worker("no_update")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("docker:update", entries)
        self.assertNotIn("docker:restart-verify", entries)
        self.assertNotIn("docker:rollback", entries)
        self.assertFalse(any(entry.startswith("sleep:") for entry in entries))

    def test_worker_stops_before_preflight_when_normalization_fails(self) -> None:
        result, entries = self.run_worker("canonicalization_failure")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docker:normalize", entries)
        self.assertNotIn("docker:preflight", entries)
        self.assertNotIn("docker:snapshot", entries)
        self.assertNotIn("docker:update", entries)
        self.assertNotIn("docker:restart-verify", entries)

    def test_worker_attempts_one_restore_after_restart_failure_without_retrying(self) -> None:
        result, entries = self.run_worker("restart_failure")

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(entries.count("docker:update"), 1)
        self.assertEqual(entries.count("docker:restart-verify"), 2)
        self.assertEqual(entries.count("docker:rollback"), 1)
        self.assertFalse(any(entry.startswith("sleep:") for entry in entries))

    def test_worker_recovers_a_duplicate_snapshot_turn_only_once(self) -> None:
        result, entries = self.run_worker(
            "recovery_duplicate",
            workspace_codex_auto_recover_interrupted_turns="true",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(entries.count("docker:restart-verify"), 1)
        self.assertEqual(entries.count("docker:recover"), 1)
        self.assertNotIn("docker:rollback", entries)

    def test_canonicalization_keeps_a_user_scoped_launcher_and_refuses_an_unknown_one(self) -> None:
        initializer = self.template("workspace-codex-update.sh.tpl")
        entrypoint = self.template("workspace-entrypoint.sh.tpl")

        self.assertIn('current_link="$standalone_dir/current"', initializer)
        self.assertIn('local_codex="$local_bin/codex"', initializer)
        self.assertIn('expected="$current_link/codex"', initializer)
        self.assertIn('ln -s "$expected" "$local_codex"', initializer)
        self.assertIn('ln -s bin/codex "$direct"', initializer)
        self.assertIn('if is_image_fallback_launcher "$literal"; then', initializer)
        self.assertIn('[ "$literal" = /usr/local/bin/codex ]', initializer)
        self.assertIn('pinned_version="$(pinned_fallback_version', initializer)
        self.assertIn('version_is_older "$current_version" "$pinned_version"', initializer)
        self.assertIn('"$0" "$inner_mode" "$workspace_user"', initializer)
        self.assertIn('--normalize-user)', initializer)
        self.assertIn("unmanaged workspace Codex launcher would be overwritten; refusing", initializer)
        self.assertIn('pinned_current=/opt/codex/packages/standalone/current', initializer)
        self.assertIn('exec runuser -u "$workspace_user" --', initializer)
        self.assertNotIn('"$0" --initialize-user "$workspace_user"', initializer)
        self.assertNotIn("AGENT_STACK_PINNED_CODEX_CURRENT", initializer)
        self.assertIn('export PATH="$home_dir/.local/bin:/usr/local/bin:', entrypoint)
        self.assertIn('agent-stack-workspace-codex-update --initialize "$username"', entrypoint)
        self.assertNotIn("--startup", entrypoint)

        worker = self.template("agent-stack-workspace-codex-update.sh.tpl")
        self.assertIn('--normalize "$workspace_user"', worker)
        self.assertNotIn('--initialize "$workspace_user"', worker)

    def test_initializer_migrates_a_trusted_two_hop_image_launcher_without_downgrade(self) -> None:
        workspace_user = "workspace"
        home = (self.root / "workspace-home").resolve()
        standalone = home / ".codex/packages/standalone"
        releases = standalone / "releases"
        old_release = releases / "0.144.1-x86_64-unknown-linux-musl"
        image_standalone = (self.root / "image-codex/packages/standalone").resolve()
        image_release = image_standalone / "releases/0.145.0-x86_64-unknown-linux-musl"

        def make_release(path: Path, version: str) -> None:
            binary = path / "bin/codex"
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_text(
                f"#!/bin/sh\nprintf 'codex-cli {version}\\n'\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            (path / "codex").symlink_to("bin/codex")

        make_release(old_release, "0.144.1")
        make_release(image_release, "0.145.0")
        standalone.mkdir(parents=True, exist_ok=True)
        (standalone / "current").symlink_to(old_release)
        image_standalone.mkdir(parents=True, exist_ok=True)
        (image_standalone / "current").symlink_to(image_release)

        local_bin = home / ".local/bin"
        local_bin.mkdir(parents=True)
        local_codex = local_bin / "codex"
        legacy_target = self.root / "legacy-image-codex"
        legacy_target.write_text("legacy link marker\n", encoding="utf-8")
        local_codex.symlink_to(legacy_target)

        initializer = self.render("workspace-codex-update.sh.tpl", workspace_username=workspace_user)
        initializer.write_text(
            initializer.read_text(encoding="utf-8").replace(
                "/opt/codex/packages/standalone", str(image_standalone)
            ),
            encoding="utf-8",
        )

        fakebin = self.root / "initializer-fakebin"
        fakebin.mkdir()

        def executable(name: str, source: str) -> None:
            path = fakebin / name
            path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
            path.chmod(0o755)

        executable(
            "id",
            """
            #!/bin/sh
            case "${1:-}" in
              -u) printf '501\\n' ;;
              -un) printf 'workspace\\n' ;;
              *) exit 1 ;;
            esac
            """,
        )
        executable(
            "getent",
            """
            #!/bin/sh
            printf 'workspace:x:501:20::%s:/bin/bash\\n' "$FAKE_WORKSPACE_HOME"
            """,
        )
        executable(
            "mv",
            """
            #!/bin/sh
            case "$1" in
              -T|-Tf|-fT) shift ;;
            esac
            exec /bin/mv "$@"
            """,
        )
        readlink_source = f"""
        #!{sys.executable}
        import os
        import sys

        args = sys.argv[1:]
        if args == [os.environ["FAKE_LOCAL_CODEX"]]:
            print("/usr/local/bin/codex")
        elif args == ["-f", "/usr/local/bin/codex"]:
            print(os.environ["FAKE_PINNED_BIN"])
        elif len(args) == 2 and args[0] == "-f":
            print(os.path.realpath(args[1]))
        elif len(args) == 1:
            print(os.readlink(args[0]))
        else:
            raise SystemExit(1)
        """
        executable("readlink", readlink_source)
        (local_bin / "readlink").write_text(textwrap.dedent(readlink_source).lstrip(), encoding="utf-8")
        (local_bin / "readlink").chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(home),
                "PATH": f"{fakebin}:/usr/bin:/bin",
                "FAKE_WORKSPACE_HOME": str(home),
                "FAKE_LOCAL_CODEX": str(local_codex),
                "FAKE_PINNED_BIN": str(image_release / "bin/codex"),
            }
        )
        result = subprocess.run(
            [str(initializer), "--initialize-user", workspace_user],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(local_codex), f"{standalone}/current/codex")
        self.assertEqual(
            os.path.realpath(standalone / "current"),
            str(releases / "agent-stack-pinned-0.145.0"),
        )
        self.assertEqual(
            subprocess.run(
                [str(local_codex), "--version"], check=True, capture_output=True, text=True
            ).stdout.strip(),
            "codex-cli 0.145.0",
        )
        self.assertTrue(list(local_bin.glob("codex.agent-stack-backup.*")))
        self.assertTrue(list(standalone.glob("current.agent-stack-backup.*")))

    def test_installer_stops_legacy_updater_before_replacing_its_contract(self) -> None:
        installer = self.template("install-agent-stack.sh.tpl")
        section = installer.split("configure_workspace_codex_auto_update() {", 1)[1].split(
            "backup_workspace_codex_auto_update_host() {", 1
        )[0]

        self.assertIn("pre-hard-cutover release could remain active indefinitely", section)
        self.assertIn('systemctl disable --now "$timer" 2>/dev/null || true', section)
        self.assertIn('systemctl stop "$unit" 2>/dev/null || true', section)
        self.assertLess(
            section.index("pre-hard-cutover release could remain active indefinitely"),
            section.index('install -m 0755 "$staging/agent-stack-workspace-codex-update"'),
        )

    def test_no_update_does_not_restart_the_app_server(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)
        commands: list[tuple[str, ...]] = []

        def fake_run(_ctx, *args: str, **_kwargs):
            commands.append(args)
            return SimpleNamespace(returncode=0, stdout="")

        with (
            patch.object(control, "version_of", side_effect=["1.2.3", "1.2.3"]),
            patch.object(control, "run_codex", side_effect=fake_run),
            patch.object(control, "context", return_value=ctx),
            patch.object(control, "canonical_binary_for_release", return_value=ctx.current_target / "codex"),
        ):
            payload = control.update(ctx)

        self.assertTrue(payload["ok"])
        self.assertFalse(payload["changed"])
        self.assertEqual(commands, [("update",)])

    def test_preflight_requires_the_managed_daemon_before_snapshot(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)

        with (
            patch.object(control, "version_of", return_value="1.2.3"),
            patch.object(control, "ensure_daemon_managed") as ensure,
        ):
            payload = control.preflight(ctx)

        self.assertEqual(
            payload,
            {
                "action": "preflight",
                "ok": True,
                "version": "1.2.3",
                "current_target": str(ctx.current_target),
            },
        )
        ensure.assert_called_once_with(ctx, expected_version="1.2.3")

    def test_rollback_points_current_back_at_the_saved_user_release(self) -> None:
        control = self.control_module()
        home = (self.root / "workspace-home").resolve()
        old_release = home / ".codex/packages/standalone/releases/1.2.3"
        new_release = home / ".codex/packages/standalone/releases/1.2.4"
        old_binary = old_release / "codex"
        old_binary.parent.mkdir(parents=True)
        old_binary.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        old_binary.chmod(0o755)
        new_binary = new_release / "codex"
        new_binary.parent.mkdir(parents=True)
        new_binary.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        new_binary.chmod(0o755)
        current = home / ".codex/packages/standalone/current"
        current.parent.mkdir(parents=True, exist_ok=True)
        current.symlink_to(new_release)
        launcher = home / ".local/bin/codex"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to(current / "codex")
        ctx = self.control_context(control, current_target=new_release)
        restored_ctx = replace(ctx, current_target=old_release)

        with (
            patch.dict(
                os.environ,
                {
                    "AGENT_STACK_CODEX_CONTROL_PREVIOUS_TARGET": str(old_release),
                    "AGENT_STACK_CODEX_CONTROL_PREVIOUS_VERSION": "1.2.3",
                },
            ),
            patch.object(control, "context", return_value=restored_ctx),
            patch.object(control, "version_of", return_value="1.2.3"),
        ):
            payload = control.rollback(ctx)

        self.assertTrue(payload["ok"])
        self.assertEqual(current.resolve(), old_release.resolve())
        self.assertEqual(launcher.resolve(), old_binary.resolve())

    def test_failed_update_restores_the_saved_target_before_retrying(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)

        with (
            patch.object(control, "version_of", return_value="1.2.3"),
            patch.object(control, "canonical_binary_for_release", return_value=ctx.current_target / "codex"),
            patch.object(control, "run_codex", side_effect=control.ControlError("command_failed")),
            patch.object(control, "restore_update_target") as restore,
        ):
            with self.assertRaises(control.ControlError) as raised:
                control.update(ctx)

        self.assertEqual(raised.exception.reason, "command_failed")
        restore.assert_called_once_with(ctx, ctx.current_target, "1.2.3")

    def test_recovery_sends_only_the_fixed_safety_prompt_for_an_interrupted_turn(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)

        class FakeRpc:
            resumed = False
            turn_start_params = None
            calls: list[tuple[str, dict]]

            def __init__(self) -> None:
                self.calls = []

            def call(self, method: str, params: dict):
                self.calls.append((method, params))
                if method == "thread/turns/list":
                    return {"data": [{"id": "turn-1", "status": "interrupted"}]}
                if method == "thread/read":
                    status = {"type": "idle" if self.resumed else "notLoaded"}
                    return {"thread": {"status": status}}
                if method == "thread/resume":
                    self.resumed = True
                    return {"thread": {"status": {"type": "idle"}}}
                if method == "turn/start":
                    self.turn_start_params = params
                    return {"turn": {"id": "recovery-turn"}}
                raise AssertionError(f"unexpected method: {method}")

        rpc = FakeRpc()

        class FakeProxy:
            def __init__(self, *_args, **_kwargs):
                pass

            def __enter__(self):
                return rpc

            def __exit__(self, *_args):
                return None

        with (
            patch.dict(
                os.environ,
                {
                    "AGENT_STACK_CODEX_CONTROL_RECOVERY_EVENT_ID": "update-1",
                    "AGENT_STACK_CODEX_CONTROL_RECOVERY_THREAD_ID": "thread-1",
                    "AGENT_STACK_CODEX_CONTROL_RECOVERY_TURN_ID": "turn-1",
                },
            ),
            patch.object(control, "JsonlProxy", FakeProxy),
        ):
            payload = control.recover(ctx)

        self.assertTrue(payload["recovered"])
        self.assertEqual(payload["thread_id"], "thread-1")
        self.assertEqual(payload["turn_id"], "recovery-turn")
        self.assertEqual(rpc.turn_start_params["clientUserMessageId"], "update-1")
        self.assertEqual(rpc.turn_start_params["input"][0]["text"], control.RECOVERY_PROMPT)
        self.assertEqual(rpc.calls[0][0], "thread/turns/list")
        self.assertEqual(rpc.calls[0][1]["sortDirection"], "desc")
        self.assertEqual(rpc.calls[0][1]["limit"], 1)
        self.assertLess(
            next(index for index, (method, _params) in enumerate(rpc.calls) if method == "thread/turns/list"),
            next(index for index, (method, _params) in enumerate(rpc.calls) if method == "thread/resume"),
        )

    def test_recovery_leaves_an_unproven_stored_thread_unloaded(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)

        class FakeRpc:
            calls: list[str]

            def __init__(self) -> None:
                self.calls = []

            def call(self, method: str, _params: dict):
                self.calls.append(method)
                if method == "thread/turns/list":
                    return {"data": [{"id": "turn-1", "status": "completed"}]}
                raise AssertionError(f"unexpected method: {method}")

        rpc = FakeRpc()

        class FakeProxy:
            def __init__(self, *_args, **_kwargs):
                pass

            def __enter__(self):
                return rpc

            def __exit__(self, *_args):
                return None

        with (
            patch.dict(
                os.environ,
                {
                    "AGENT_STACK_CODEX_CONTROL_RECOVERY_EVENT_ID": "update-1",
                    "AGENT_STACK_CODEX_CONTROL_RECOVERY_THREAD_ID": "thread-1",
                    "AGENT_STACK_CODEX_CONTROL_RECOVERY_TURN_ID": "turn-1",
                },
            ),
            patch.object(control, "JsonlProxy", FakeProxy),
        ):
            payload = control.recover(ctx)

        self.assertFalse(payload["recovered"])
        self.assertEqual(rpc.calls, ["thread/turns/list"])

    def test_recovery_is_ledger_deduplicated_and_skips_waiting_turns(self) -> None:
        worker = self.template("agent-stack-workspace-codex-update.sh.tpl")
        helper = self.template("workspace-codex-control.py.tpl")

        self.assertIn("set -C; : >\"$marker\"", worker)
        self.assertIn("already_marked", worker)
        self.assertIn("select(.recoveryEligible == true)", worker)
        self.assertIn('"recoveryEligible": not flags', helper)
        self.assertIn("not_recoverable", helper)
        self.assertNotIn("AGENT_STACK_CODEX_CONTROL_TEST_", helper)

    def test_diagnostics_accepts_only_the_fixed_update_bridge_operations(self) -> None:
        diagnostics = self.template("agent-stack-diagnostics.sh.tpl")

        self.assertIn("agent-stack-diagnostics codex-update", diagnostics)
        self.assertIn("agent-stack-diagnostics codex-update status", diagnostics)
        self.assertIn("systemctl start --no-block agent-stack-workspace-codex-update.service", diagnostics)
        self.assertIn("case $# in", diagnostics)
        self.assertIn("beforeVersion:(.data.before_version // \"\")", diagnostics)
        self.assertNotIn("{at,eventId,phase,attempt,outcome,data}", diagnostics)
        self.assertNotIn("docker.sock", diagnostics)

    def test_diagnostics_rejects_extra_or_unknown_codex_update_arguments(self) -> None:
        diagnostics = self.render("agent-stack-diagnostics.sh.tpl")

        for arguments in (("codex-update", "restart"), ("codex-update", "status", "extra")):
            result = subprocess.run(
                [str(diagnostics), *arguments],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
                env={**os.environ, "PATH": "/usr/bin:/bin"},
            )
            self.assertEqual(result.returncode, 64, result.stderr)
            self.assertNotIn("docker", result.stderr.lower())


class WorkspaceCodexDaemonPreflightSafetyTest(unittest.TestCase):
    """Safety tests for the fixed-purpose managed app-server enrollment path."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def template(self, name: str) -> str:
        return (RUNTIME_DIR / name).read_text(encoding="utf-8")

    def control_module(self):
        loader = SourceFileLoader(
            "agent_stack_workspace_codex_daemon_preflight_test",
            str(RUNTIME_DIR / "workspace-codex-control.py.tpl"),
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module

    def control_context(self, control):
        home = (self.root / "workspace-home").resolve()
        release = home / ".codex/packages/standalone/releases/1.2.3"
        standalone = home / ".codex/packages/standalone"
        return control.Context(
            home=home,
            codex_home=home / ".codex",
            standalone=standalone,
            releases=standalone / "releases",
            current=standalone / "current",
            current_target=release,
            launcher=home / ".local/bin/codex",
            command_bin=home / ".local/bin/codex",
            socket_path=home / ".codex/app-server-control/app-server-control.sock",
            pid_file=home / ".codex/app-server-daemon/app-server.pid",
            updater_pid_file=home / ".codex/app-server-daemon/app-server-updater.pid",
            username="workspace",
            uid=1000,
        )

    def test_pid_state_requires_codex_json_record_not_a_raw_pid(self) -> None:
        control = self.control_module()
        raw_pid = self.root / "app-server.pid"
        raw_pid.write_text("4242\n", encoding="utf-8")

        # A raw PID cannot establish daemon ownership and must not even be
        # probed as a live process.
        with patch.object(control.os, "kill") as kill:
            state, record = control.read_pid_record(raw_pid)

        self.assertEqual(state, "malformed")
        self.assertIsNone(record)
        kill.assert_not_called()

        start_time = "Wed Jul 23 04:00:00 2026"
        raw_pid.write_text(
            '{"pid":4242,"processStartTime":"' + start_time + '"}',
            encoding="utf-8",
        )
        with (
            patch.object(control.os, "kill") as kill,
            patch.object(
                control.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=0, stdout=f"{start_time}\n"),
            ) as process,
        ):
            state, record = control.read_pid_record(raw_pid)

        self.assertEqual(state, "active")
        self.assertEqual(record, control.PidRecord(pid=4242, process_start_time=start_time))
        kill.assert_called_once_with(4242, 0)
        process.assert_called_once_with(
            ["ps", "-p", "4242", "-o", "lstart="],
            check=False,
            stdin=control.subprocess.DEVNULL,
            stdout=control.subprocess.PIPE,
            stderr=control.subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
        )

    def test_active_bootstrap_updater_blocks_daemon_start_before_mutation(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)
        updater_record = control.PidRecord(
            pid=4242,
            process_start_time="Wed Jul 23 04:00:00 2026",
        )

        with (
            patch.object(control, "read_pid_record", return_value=("active", updater_record)) as read_record,
            patch.object(control, "daemon_payload") as daemon_start,
        ):
            with self.assertRaises(control.ControlError) as raised:
                control.ensure_daemon_managed(ctx, expected_version="1.2.3")

        self.assertEqual(raised.exception.reason, "auto_update_loop_active")
        read_record.assert_called_once_with(ctx.updater_pid_file)
        daemon_start.assert_not_called()

    def test_daemon_start_accepts_only_a_managed_pid_backend(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)
        managed_payload = {
            "status": "started",
            "backend": "pid",
            "managedCodexPath": str(ctx.current / "codex"),
            "socketPath": str(ctx.socket_path),
        }

        with (
            patch.object(control, "reject_bootstrap_updater") as reject_updater,
            patch.object(control, "daemon_payload", return_value=managed_payload) as daemon_start,
            patch.object(control, "wait_for_managed_daemon", return_value=True) as wait_for_daemon,
        ):
            control.ensure_daemon_managed(ctx, expected_version="1.2.3")

        daemon_start.assert_called_once_with(
            ctx,
            "start",
            timeout=control.DAEMON_COMMAND_TIMEOUT_SECONDS,
        )
        wait_for_daemon.assert_called_once_with(ctx, "1.2.3")
        self.assertEqual(reject_updater.call_count, 2)

    def test_daemon_start_rejects_already_running_server_without_pid_backend(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)
        unmanaged_payload = {
            "status": "alreadyRunning",
            "managedCodexPath": str(ctx.current / "codex"),
            "socketPath": str(ctx.socket_path),
        }

        with (
            patch.object(control, "reject_bootstrap_updater"),
            patch.object(control, "daemon_payload", return_value=unmanaged_payload) as daemon_start,
            patch.object(control, "wait_for_managed_daemon") as wait_for_daemon,
        ):
            with self.assertRaises(control.ControlError) as raised:
                control.ensure_daemon_managed(ctx, expected_version="1.2.3")

        self.assertEqual(raised.exception.reason, "unmanaged_app_server")
        daemon_start.assert_called_once_with(
            ctx,
            "start",
            timeout=control.DAEMON_COMMAND_TIMEOUT_SECONDS,
        )
        wait_for_daemon.assert_not_called()

    def test_restart_verification_does_not_recycle_a_daemon_just_started_from_current(self) -> None:
        control = self.control_module()
        ctx = self.control_context(control)

        with (
            patch.object(control, "version_of", return_value="1.2.4"),
            patch.object(control, "ensure_daemon_managed", return_value="started") as ensure,
            patch.object(control, "wait_for_managed_daemon", return_value=True) as wait_for_daemon,
            patch.object(control, "daemon_payload") as daemon_restart,
        ):
            payload = control.restart_verify(ctx)

        self.assertTrue(payload["ok"])
        self.assertTrue(payload["daemon_started"])
        ensure.assert_called_once_with(ctx, expected_version=None)
        wait_for_daemon.assert_called_once_with(ctx, "1.2.4")
        daemon_restart.assert_not_called()

    def test_helper_never_invokes_codex_daemon_bootstrap(self) -> None:
        helper = self.template("workspace-codex-control.py.tpl")

        # The word appears in explanatory comments, but it must never be an
        # executable fixed command: bootstrap installs Codex's own hourly loop.
        self.assertNotIn('daemon_payload(ctx, "bootstrap"', helper)
        self.assertNotIn('run_codex(ctx, "app-server", "daemon", "bootstrap"', helper)


if __name__ == "__main__":
    unittest.main()
