#!/usr/bin/env python3
"""Narrow, user-scoped control plane for the workspace Codex app-server.

This program is installed root-owned, but is deliberately run as the workspace
user by the host maintenance service.  It accepts no caller-provided RPC
methods, prompts, commands, or filesystem paths.  Its JSON stdout is a small,
machine-readable result for the root-side coordinator; stderr and subprocess
output are intentionally discarded so it cannot leak Codex state or tokens.
"""

from __future__ import annotations

import json
import os
import pwd
import queue
import re
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final


ALLOWED_ACTIONS: Final = {"preflight", "snapshot", "update", "restart-verify", "rollback", "recover"}
RETRYABLE_PRE_RESTART_ERRORS: Final = {
    "workspace_home_unavailable",
    "socket_unavailable",
    "proxy_unavailable",
    "rpc_timeout",
    "rpc_error",
    "command_timeout",
    "command_unavailable",
    "command_failed",
    "version_unavailable",
}
ID_RE: Final = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$")
VERSION_RE: Final = re.compile(r"\bcodex-cli\s+([0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9._-]+)?)\b")
STABLE_VERSION_RE: Final = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
MAX_LOADED_THREADS: Final = 256
RPC_TIMEOUT_SECONDS: Final = 15.0
RESTART_VERIFY_SECONDS: Final = 30.0
DAEMON_COMMAND_TIMEOUT_SECONDS: Final = 60.0
RECOVERY_PROMPT: Final = (
    "A scheduled Codex CLI update restarted the app-server and interrupted your prior turn. "
    "Do not repeat external or destructive actions. First inspect the thread and current "
    "workspace/runtime state, report what remains, and wait for the user before taking further action."
)


class ControlError(Exception):
    """A deliberately non-sensitive failure reason exposed to the coordinator."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def emit(payload: dict[str, Any]) -> None:
    """Write exactly one non-sensitive JSON document to stdout."""

    sys.stdout.write(json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n")
    sys.stdout.flush()


def required_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise ControlError("missing_control_input")
    return value


def valid_identifier(value: str) -> str:
    if not ID_RE.fullmatch(value):
        raise ControlError("invalid_control_input")
    return value


def is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def resolve_existing(path: Path, reason: str) -> Path:
    try:
        return path.resolve(strict=True)
    except (OSError, RuntimeError):
        raise ControlError(reason) from None


def canonical_binary_for_release(release: Path) -> Path:
    """Resolve the app-server daemon's canonical standalone launcher."""

    # The managed app-server daemon resolves `current/codex` itself.  Modern
    # packages provide it as a shim to bin/codex; the root bootstrap creates
    # that shim for an older package before this user-scoped helper can run.
    candidate = release / "codex"
    try:
        resolved = candidate.resolve(strict=True)
    except (OSError, RuntimeError):
        raise ControlError("canonical_install_invalid") from None
    if resolved.is_file() and os.access(resolved, os.X_OK) and is_relative_to(resolved, release):
        return resolved
    raise ControlError("canonical_install_invalid")


def effective_home() -> Path:
    try:
        return Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(strict=True)
    except (KeyError, OSError, RuntimeError):
        raise ControlError("workspace_home_unavailable") from None


@dataclass(frozen=True)
class Context:
    home: Path
    codex_home: Path
    standalone: Path
    releases: Path
    current: Path
    current_target: Path
    launcher: Path
    command_bin: Path
    socket_path: Path
    pid_file: Path
    updater_pid_file: Path
    username: str
    uid: int


def context() -> Context:
    home = effective_home()
    try:
        username = pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        raise ControlError("workspace_home_unavailable") from None
    codex_home = home / ".codex"
    standalone = codex_home / "packages" / "standalone"
    # The pinned bootstrap uses `releases/`, but a valid existing standalone
    # installation may use an older direct-child layout.  The canonical
    # invariant is the user-scoped `current` target, not an implementation
    # detail of a particular installer version.
    releases = standalone / "releases"
    current = standalone / "current"
    if not current.is_symlink():
        raise ControlError("canonical_install_invalid")
    current_target = resolve_existing(current, "canonical_install_invalid")
    if not is_relative_to(current_target, standalone) or current_target == standalone or not current_target.is_dir():
        raise ControlError("canonical_install_invalid")
    canonical_bin = canonical_binary_for_release(current_target)

    launcher = home / ".local" / "bin" / "codex"
    if not launcher.is_symlink() or resolve_existing(launcher, "canonical_install_invalid") != canonical_bin:
        raise ControlError("canonical_install_invalid")
    # Invoke the user-scoped launcher, not the resolved release binary, so the
    # official updater owns the `current` target transition.
    command_bin = launcher

    socket_path = codex_home / "app-server-control" / "app-server-control.sock"

    return Context(
        home=home,
        codex_home=codex_home,
        standalone=standalone,
        releases=releases,
        current=current,
        current_target=current_target,
        launcher=launcher,
        command_bin=command_bin,
        socket_path=socket_path,
        pid_file=codex_home / "app-server-daemon" / "app-server.pid",
        updater_pid_file=codex_home / "app-server-daemon" / "app-server-updater.pid",
        username=username,
        uid=os.getuid(),
    )


def command_env(ctx: Context) -> dict[str, str]:
    """Use a narrow, deterministic environment while retaining network proxy support."""

    env = {
        "HOME": str(ctx.home),
        "USER": ctx.username,
        "LOGNAME": ctx.username,
        "CODEX_HOME": str(ctx.codex_home),
        "PATH": f"{ctx.home / '.local' / 'bin'}:/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    for name in (
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
    ):
        if name in os.environ:
            env[name] = os.environ[name]
    return env


def socket_is_valid(ctx: Context) -> bool:
    try:
        entry = os.lstat(ctx.socket_path)
        target = os.stat(ctx.socket_path)
    except OSError:
        return False
    return not stat.S_ISLNK(entry.st_mode) and stat.S_ISSOCK(target.st_mode) and target.st_uid == ctx.uid


def version_of(ctx: Context) -> str:
    try:
        completed = subprocess.run(
            [str(ctx.command_bin), "--version"],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=20,
            cwd=ctx.home,
            env=command_env(ctx),
        )
    except (OSError, subprocess.TimeoutExpired):
        raise ControlError("version_unavailable") from None
    if completed.returncode != 0:
        raise ControlError("version_unavailable")
    match = VERSION_RE.search(completed.stdout)
    if not match:
        raise ControlError("version_unavailable")
    return match.group(1)


def run_codex(ctx: Context, *args: str, timeout: float) -> subprocess.CompletedProcess[str]:
    try:
        completed = subprocess.run(
            [str(ctx.command_bin), *args],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            cwd=ctx.home,
            env=command_env(ctx),
        )
    except subprocess.TimeoutExpired:
        raise ControlError("command_timeout") from None
    except OSError:
        raise ControlError("command_unavailable") from None
    if completed.returncode != 0:
        raise ControlError("command_failed")
    return completed


class JsonlProxy:
    """A single-connection, fixed-method JSONL client for `codex app-server proxy`."""

    def __init__(self, ctx: Context, *, experimental: bool = False) -> None:
        self.ctx = ctx
        self.experimental = experimental
        self.proc: subprocess.Popen[str] | None = None
        self.messages: queue.Queue[object] = queue.Queue()
        self.next_id = 1
        self.write_lock = threading.Lock()

    def __enter__(self) -> "JsonlProxy":
        if not socket_is_valid(self.ctx):
            raise ControlError("socket_unavailable")
        command = [str(self.ctx.command_bin), "app-server", "proxy", "--sock", str(self.ctx.socket_path)]
        try:
            self.proc = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                cwd=self.ctx.home,
                env=command_env(self.ctx),
            )
        except OSError:
            raise ControlError("proxy_unavailable") from None
        if self.proc.stdin is None or self.proc.stdout is None:
            self.close()
            raise ControlError("proxy_unavailable")
        threading.Thread(target=self._read_loop, name="codex-control-proxy", daemon=True).start()
        capabilities: dict[str, Any] = {}
        if self.experimental:
            capabilities["experimentalApi"] = True
        self.call(
            "initialize",
            {
                "clientInfo": {
                    "name": "agent-stack-workspace-codex-control",
                    "title": "AgentStack workspace Codex maintenance",
                    "version": "1",
                },
                "capabilities": capabilities,
            },
        )
        self.notify("initialized", {})
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def _read_loop(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        try:
            for line in self.proc.stdout:
                if len(line) > 8 * 1024 * 1024:
                    self.messages.put(ControlError("protocol_error"))
                    return
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    self.messages.put(ControlError("protocol_error"))
                    return
                if not isinstance(value, dict):
                    self.messages.put(ControlError("protocol_error"))
                    return
                self.messages.put(value)
        finally:
            self.messages.put(None)

    def _send(self, message: dict[str, Any]) -> None:
        if self.proc is None or self.proc.stdin is None:
            raise ControlError("proxy_unavailable")
        try:
            with self.write_lock:
                self.proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
                self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            raise ControlError("proxy_unavailable") from None

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self._send({"method": method, "params": params})

    def call(self, method: str, params: dict[str, Any], *, timeout: float = RPC_TIMEOUT_SECONDS) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        self._send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ControlError("rpc_timeout")
            try:
                message = self.messages.get(timeout=remaining)
            except queue.Empty:
                raise ControlError("rpc_timeout") from None
            if message is None:
                raise ControlError("proxy_unavailable")
            if isinstance(message, ControlError):
                raise message
            if not isinstance(message, dict):
                raise ControlError("protocol_error")

            # App-server can make a server-to-client request. This maintenance
            # client never approves or supplies input; reject it explicitly.
            if "method" in message and "id" in message:
                self._send(
                    {
                        "id": message["id"],
                        "error": {"code": -32601, "message": "unsupported control client request"},
                    }
                )
                continue
            if "method" in message:
                continue
            if message.get("id") != request_id:
                raise ControlError("protocol_error")
            if "error" in message:
                raise ControlError("rpc_error")
            result = message.get("result")
            if not isinstance(result, dict):
                raise ControlError("protocol_error")
            return result

    def close(self) -> None:
        proc = self.proc
        self.proc = None
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)


def thread_status(thread: object) -> dict[str, Any] | None:
    if not isinstance(thread, dict):
        return None
    status = thread.get("status")
    return status if isinstance(status, dict) else None


def snapshot(ctx: Context) -> dict[str, Any]:
    active: list[dict[str, Any]] = []
    with JsonlProxy(ctx) as rpc:
        cursor: str | None = None
        seen: set[str] = set()
        while True:
            params: dict[str, Any] = {"limit": 100}
            if cursor is not None:
                params["cursor"] = cursor
            page = rpc.call("thread/loaded/list", params)
            ids = page.get("data")
            if not isinstance(ids, list):
                raise ControlError("protocol_error")
            for raw_thread_id in ids:
                if not isinstance(raw_thread_id, str):
                    raise ControlError("protocol_error")
                thread_id = valid_identifier(raw_thread_id)
                if thread_id in seen:
                    continue
                seen.add(thread_id)
                if len(seen) > MAX_LOADED_THREADS:
                    raise ControlError("snapshot_too_large")
                response = rpc.call("thread/read", {"threadId": thread_id, "includeTurns": True})
                thread = response.get("thread")
                status = thread_status(thread)
                if status is None or status.get("type") != "active":
                    continue
                turns = thread.get("turns") if isinstance(thread, dict) else None
                if not isinstance(turns, list):
                    raise ControlError("protocol_error")
                flags = status.get("activeFlags")
                if not isinstance(flags, list) or not all(isinstance(flag, str) for flag in flags):
                    raise ControlError("protocol_error")
                for turn in turns:
                    if not isinstance(turn, dict) or turn.get("status") != "inProgress":
                        continue
                    raw_turn_id = turn.get("id")
                    if not isinstance(raw_turn_id, str):
                        raise ControlError("protocol_error")
                    active.append(
                        {
                            "threadId": thread_id,
                            "turnId": valid_identifier(raw_turn_id),
                            "recoveryEligible": not flags,
                        }
                    )
            next_cursor = page.get("nextCursor")
            if next_cursor is None:
                break
            if not isinstance(next_cursor, str) or not next_cursor:
                raise ControlError("protocol_error")
            cursor = next_cursor
    return {"action": "snapshot", "ok": True, "snapshot": active}


def update(ctx: Context) -> dict[str, Any]:
    before = version_of(ctx)
    if not STABLE_VERSION_RE.fullmatch(before):
        raise ControlError("non_stable_current")
    before_target = ctx.current_target
    canonical_binary_for_release(before_target)
    try:
        run_codex(ctx, "update", timeout=240)
        after_ctx = context()
        after = version_of(after_ctx)
        target_changed = before_target != after_ctx.current_target
        if not STABLE_VERSION_RE.fullmatch(after):
            raise ControlError("non_stable_update")
        if before != after and not target_changed:
            raise ControlError("update_target_not_changed")
    except ControlError as error:
        # An updater may fail after switching the visible target.  Re-establish
        # the known-good target and launcher before returning a retryable
        # pre-restart error; no failed update can become live accidentally.
        try:
            restore_update_target(ctx, before_target, before)
        except ControlError:
            raise ControlError("update_rollback_failed") from None
        raise error
    return {
        "action": "update",
        "ok": True,
        "changed": before != after,
        "before_version": before,
        "after_version": after,
        # This value is consumed only by the root-side coordinator to drive
        # the fixed rollback action; it is never printed by diagnostics.
        "previous_target": str(before_target),
        "target_changed": target_changed,
    }


@dataclass(frozen=True)
class PidRecord:
    """The exact JSON record format written by Codex's PID daemon backend."""

    pid: int
    process_start_time: str


def read_pid_record(path: Path) -> tuple[str, PidRecord | None]:
    """Return missing, stale, active, malformed, or ambiguous for a PID file.

    Codex deliberately protects against PID reuse by recording the verbatim
    `ps -p <pid> -o lstart=` value.  Match that value exactly instead of
    treating a raw numeric PID as managed daemon state.
    """

    try:
        entry = path.lstat()
    except FileNotFoundError:
        return "missing", None
    except OSError:
        return "ambiguous", None
    if stat.S_ISLNK(entry.st_mode) or not stat.S_ISREG(entry.st_mode):
        return "malformed", None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return "malformed", None
    if not isinstance(payload, dict):
        return "malformed", None
    pid = payload.get("pid")
    process_start_time = payload.get("processStartTime")
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return "malformed", None
    if not isinstance(process_start_time, str) or not process_start_time:
        return "malformed", None
    record = PidRecord(pid=pid, process_start_time=process_start_time)
    try:
        os.kill(record.pid, 0)
    except ProcessLookupError:
        return "stale", record
    except (PermissionError, OSError):
        return "ambiguous", record
    try:
        completed = subprocess.run(
            ["ps", "-p", str(record.pid), "-o", "lstart="],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "ambiguous", record
    if completed.returncode != 0:
        return "stale", record
    if completed.stdout.strip() != record.process_start_time:
        return "stale", record
    return "active", record


def daemon_pid_matches(ctx: Context, *, require_current_target: bool) -> bool:
    state, record = read_pid_record(ctx.pid_file)
    if state != "active" or record is None:
        return False
    try:
        executable = Path(os.readlink(f"/proc/{record.pid}/exe")).resolve(strict=True)
    except (OSError, RuntimeError):
        return False
    parent = ctx.current_target if require_current_target else ctx.standalone
    return is_relative_to(executable, parent)


def daemon_payload(ctx: Context, *args: str, timeout: float) -> dict[str, Any]:
    completed = run_codex(ctx, "app-server", "daemon", *args, timeout=timeout)
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        raise ControlError("daemon_management_unavailable") from None
    if not isinstance(payload, dict):
        raise ControlError("daemon_management_unavailable")
    return payload


def daemon_payload_matches(
    ctx: Context,
    payload: dict[str, Any],
    *,
    statuses: set[str],
    expected_version: str | None = None,
) -> bool:
    if payload.get("status") not in statuses or payload.get("backend") != "pid":
        return False
    if payload.get("managedCodexPath") != str(ctx.current / "codex"):
        return False
    if payload.get("socketPath") != str(ctx.socket_path):
        return False
    if expected_version is not None and (
        payload.get("cliVersion") != expected_version or payload.get("appServerVersion") != expected_version
    ):
        return False
    return True


def reject_bootstrap_updater(ctx: Context) -> None:
    state, _record = read_pid_record(ctx.updater_pid_file)
    if state == "active":
        # Codex's legacy daemon updater owns an hourly install loop.  The
        # scheduled AgentStack worker must never overlap it or silently add
        # another updater schedule.
        raise ControlError("auto_update_loop_active")
    if state in {"malformed", "ambiguous"}:
        raise ControlError("daemon_state_ambiguous")


def wait_for_managed_daemon(ctx: Context, expected_version: str | None) -> bool:
    deadline = time.monotonic() + RESTART_VERIFY_SECONDS
    while time.monotonic() < deadline:
        if expected_version is None:
            if daemon_pid_matches(ctx, require_current_target=False):
                return True
        elif daemon_is_ready(ctx, expected_version):
            return True
        time.sleep(1)
    return False


def ensure_daemon_managed(ctx: Context, *, expected_version: str | None) -> str:
    """Start only Codex's managed daemon and reject any live unmanaged server.

    The fixed daemon-start operation is intentionally used instead of Codex's
    separate hourly updater mode, which would violate the configured
    04:00-only maintenance window.
    """

    reject_bootstrap_updater(ctx)
    payload = daemon_payload(ctx, "start", timeout=DAEMON_COMMAND_TIMEOUT_SECONDS)
    if payload.get("status") == "alreadyRunning" and payload.get("backend") != "pid":
        raise ControlError("unmanaged_app_server")
    if not daemon_payload_matches(ctx, payload, statuses={"started", "alreadyRunning"}):
        raise ControlError("daemon_management_unavailable")
    reject_bootstrap_updater(ctx)
    if not wait_for_managed_daemon(ctx, expected_version):
        raise ControlError("daemon_management_unavailable")
    return str(payload["status"])


def daemon_version_matches(ctx: Context, expected_version: str) -> bool:
    try:
        payload = daemon_payload(ctx, "version", timeout=10)
    except ControlError:
        return False
    return daemon_payload_matches(ctx, payload, statuses={"running"}, expected_version=expected_version)


def daemon_is_ready(ctx: Context, expected_version: str) -> bool:
    if not socket_is_valid(ctx):
        return False
    if not daemon_version_matches(ctx, expected_version):
        return False
    if not daemon_pid_matches(ctx, require_current_target=True):
        return False
    try:
        with JsonlProxy(ctx) as rpc:
            rpc.call("thread/loaded/list", {"limit": 1}, timeout=5)
    except ControlError:
        return False
    return True


def preflight(ctx: Context) -> dict[str, Any]:
    expected_version = version_of(ctx)
    ensure_daemon_managed(ctx, expected_version=expected_version)
    # The host coordinator retains this rollback-safe reference before it
    # invokes `codex update`; it is never written to its root-only ledger.
    return {
        "action": "preflight",
        "ok": True,
        "version": expected_version,
        "current_target": str(ctx.current_target),
    }


def restart_verify(ctx: Context) -> dict[str, Any]:
    expected_version = version_of(ctx)
    # The target can already have moved when this executes, so ownership is
    # checked against the standalone tree before the restart, not against the
    # new `current` target.  The post-restart check below requires the latter.
    daemon_start_status = ensure_daemon_managed(ctx, expected_version=None)
    if daemon_start_status == "started":
        # The daemon disappeared between snapshot and maintenance.  Starting
        # it from the new canonical target already gives us the desired live
        # version; restarting it again would add a needless second cutover.
        if wait_for_managed_daemon(ctx, expected_version):
            return {
                "action": "restart-verify",
                "ok": True,
                "after_version": expected_version,
                "daemon_started": True,
            }
        raise ControlError("restart_verification_failed")
    payload = daemon_payload(ctx, "restart", timeout=DAEMON_COMMAND_TIMEOUT_SECONDS)
    if not daemon_payload_matches(ctx, payload, statuses={"restarted"}):
        raise ControlError("daemon_restart_unavailable")
    deadline = time.monotonic() + RESTART_VERIFY_SECONDS
    while time.monotonic() < deadline:
        try:
            current_ctx = context()
            if version_of(current_ctx) == expected_version and daemon_is_ready(current_ctx, expected_version):
                return {"action": "restart-verify", "ok": True, "after_version": expected_version}
        except ControlError:
            pass
        time.sleep(1)
    raise ControlError("restart_verification_failed")


def validated_previous_target(ctx: Context) -> Path:
    raw_target = required_env("AGENT_STACK_CODEX_CONTROL_PREVIOUS_TARGET")
    target = Path(raw_target)
    if not target.is_absolute():
        raise ControlError("invalid_control_input")
    resolved = resolve_existing(target, "invalid_control_input")
    if not is_relative_to(resolved, ctx.standalone) or resolved == ctx.standalone or not resolved.is_dir():
        raise ControlError("invalid_control_input")
    canonical_binary_for_release(resolved)
    return resolved


def validated_previous_version() -> str:
    version = required_env("AGENT_STACK_CODEX_CONTROL_PREVIOUS_VERSION")
    if not STABLE_VERSION_RE.fullmatch(version):
        raise ControlError("invalid_control_input")
    return version


def atomically_point_current(current: Path, target: Path) -> None:
    temporary = current.with_name(f".{current.name}.agent-stack-{os.getpid()}")
    try:
        if os.path.lexists(temporary):
            raise ControlError("rollback_unavailable")
        os.symlink(str(target), temporary)
        os.replace(temporary, current)
    except ControlError:
        raise
    except OSError:
        raise ControlError("rollback_unavailable") from None
    finally:
        try:
            if os.path.lexists(temporary):
                os.unlink(temporary)
        except OSError:
            pass


def atomically_point_launcher(launcher: Path, current: Path) -> None:
    temporary = launcher.with_name(f".{launcher.name}.agent-stack-{os.getpid()}")
    try:
        if os.path.lexists(temporary):
            raise ControlError("rollback_unavailable")
        os.symlink(str(current / "codex"), temporary)
        os.replace(temporary, launcher)
    except ControlError:
        raise
    except OSError:
        raise ControlError("rollback_unavailable") from None
    finally:
        try:
            if os.path.lexists(temporary):
                os.unlink(temporary)
        except OSError:
            pass


def restore_update_target(ctx: Context, previous_target: Path, previous_version: str) -> None:
    canonical_binary_for_release(previous_target)
    atomically_point_current(ctx.current, previous_target)
    atomically_point_launcher(ctx.launcher, ctx.current)
    restored = context()
    if restored.current_target != previous_target or version_of(restored) != previous_version:
        raise ControlError("rollback_verification_failed")


def rollback(ctx: Context) -> dict[str, Any]:
    previous_target = validated_previous_target(ctx)
    previous_version = validated_previous_version()
    prior_current = ctx.current_target
    prior_version = version_of(ctx)
    try:
        # This repairs both pointers.  `codex update` may alter the user
        # launcher as well as `current`, so moving only current would leave a
        # mismatched command after a failed daemon restart.
        restore_update_target(ctx, previous_target, previous_version)
    except ControlError:
        # A failed rollback verification must not leave a partial pointer change.
        try:
            restore_update_target(ctx, prior_current, prior_version)
        except ControlError:
            pass
        raise ControlError("rollback_verification_failed") from None
    return {
        "action": "rollback",
        "ok": True,
        "after_version": previous_version,
        "previous_target": str(previous_target),
    }


def read_thread_status(rpc: JsonlProxy, thread_id: str) -> dict[str, Any]:
    """Read only the live state, which also works for `notLoaded` threads."""

    response = rpc.call("thread/read", {"threadId": thread_id, "includeTurns": False})
    status = thread_status(response.get("thread"))
    if status is None:
        raise ControlError("protocol_error")
    return status


def read_latest_turn(rpc: JsonlProxy, thread_id: str) -> dict[str, Any] | None:
    """Read the newest persisted turn without assuming `thread/read` ordering."""

    response = rpc.call(
        "thread/turns/list",
        {
            "threadId": thread_id,
            "limit": 1,
            "sortDirection": "desc",
            "itemsView": "notLoaded",
        },
    )
    turns = response.get("data")
    if not isinstance(turns, list):
        raise ControlError("protocol_error")
    if not turns:
        return None
    latest = turns[0]
    if not isinstance(latest, dict):
        raise ControlError("protocol_error")
    return latest


def recover(ctx: Context) -> dict[str, Any]:
    # These are set only by the root-side coordinator's fixed docker-exec call.
    # They are identifiers, not user input, paths, commands, or prompt text.
    _event_id = valid_identifier(required_env("AGENT_STACK_CODEX_CONTROL_RECOVERY_EVENT_ID"))
    thread_id = valid_identifier(required_env("AGENT_STACK_CODEX_CONTROL_RECOVERY_THREAD_ID"))
    turn_id = valid_identifier(required_env("AGENT_STACK_CODEX_CONTROL_RECOVERY_TURN_ID"))

    with JsonlProxy(ctx, experimental=True) as rpc:
        # Prove that the stored thread ends with the captured interrupted turn
        # before loading it.  A stale or completed stored thread must remain
        # untouched by maintenance.
        latest = read_latest_turn(rpc, thread_id)
        if latest is None or latest.get("id") != turn_id or latest.get("status") != "interrupted":
            return {"action": "recover", "ok": True, "recovered": False, "error": "not_recoverable"}

        status = read_thread_status(rpc, thread_id)
        if status.get("type") == "notLoaded":
            rpc.call("thread/resume", {"threadId": thread_id, "excludeTurns": True})
            status = read_thread_status(rpc, thread_id)
        if status is None or status.get("type") != "idle":
            return {"action": "recover", "ok": True, "recovered": False, "error": "not_recoverable"}

        # A desktop client might have resumed or continued the thread during
        # the previous calls. Require the captured interrupted turn to remain
        # the newest stored turn before appending anything.
        latest = read_latest_turn(rpc, thread_id)
        if latest is None or latest.get("id") != turn_id or latest.get("status") != "interrupted":
            return {"action": "recover", "ok": True, "recovered": False, "error": "not_recoverable"}
        status = read_thread_status(rpc, thread_id)
        if status is None or status.get("type") != "idle":
            return {"action": "recover", "ok": True, "recovered": False, "error": "not_recoverable"}

        # Close the remaining race with a client that starts a new turn just
        # before maintenance does.  The root ledger makes the subsequent
        # turn/start at-most-once even if its response is lost.
        latest = read_latest_turn(rpc, thread_id)
        if latest is None or latest.get("id") != turn_id or latest.get("status") != "interrupted":
            return {"action": "recover", "ok": True, "recovered": False, "error": "not_recoverable"}

        started = rpc.call(
            "turn/start",
            {
                "threadId": thread_id,
                "input": [{"type": "text", "text": RECOVERY_PROMPT}],
                "clientUserMessageId": _event_id,
            },
        )
        turn = started.get("turn")
        if not isinstance(turn, dict) or not isinstance(turn.get("id"), str):
            raise ControlError("protocol_error")
        return {
            "action": "recover",
            "ok": True,
            "recovered": True,
            "thread_id": thread_id,
            "turn_id": valid_identifier(turn["id"]),
        }


def run(action: str) -> dict[str, Any]:
    if os.geteuid() == 0:
        raise ControlError("must_run_as_workspace_user")
    ctx = context()
    if action == "preflight":
        return preflight(ctx)
    if action == "snapshot":
        return snapshot(ctx)
    if action == "update":
        return update(ctx)
    if action == "restart-verify":
        return restart_verify(ctx)
    if action == "rollback":
        return rollback(ctx)
    if action == "recover":
        return recover(ctx)
    raise ControlError("invalid_action")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ALLOWED_ACTIONS:
        emit({"action": "invalid", "ok": False, "error": "invalid_action"})
        return 64
    action = sys.argv[1]
    try:
        emit(run(action))
        return 0
    except ControlError as error:
        emit({"action": action, "ok": False, "error": error.reason})
        if action in {"preflight", "snapshot", "update"} and error.reason in RETRYABLE_PRE_RESTART_ERRORS:
            return 75
        return 1
    except Exception:
        emit({"action": action, "ok": False, "error": "internal_error"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
