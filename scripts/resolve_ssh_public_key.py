#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def parse_query() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        query = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"invalid query JSON: {exc}")
    if not isinstance(query, dict):
        fail("query must be a JSON object")
    return query


def chmod_if_exists(path: Path, mode: int) -> None:
    if path.exists():
        path.chmod(mode)


def resolve_public_key(repo_root: Path, private_relpath: str) -> tuple[str, str, Path]:
    private_path = (repo_root / private_relpath).resolve()
    public_path = Path(f"{private_path}.pub")

    if public_path.exists() and public_path.stat().st_size > 0:
        return public_path.read_text(encoding="utf-8").strip(), "existing_public_key", public_path

    if private_path.exists():
        private_path.parent.mkdir(parents=True, exist_ok=True)
        pub = subprocess.check_output(
            ["ssh-keygen", "-y", "-f", str(private_path)],
            text=True,
        ).strip()
        public_path.write_text(pub + "\n", encoding="utf-8")
        chmod_if_exists(private_path, 0o600)
        chmod_if_exists(public_path, 0o644)
        return pub, "derived_from_private_key", public_path

    private_path.parent.mkdir(parents=True, exist_ok=True)
    chmod_if_exists(private_path.parent, 0o700)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    comment = f"agent-stack@{socket.gethostname()}-{ts}"

    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-C", comment, "-f", str(private_path)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    chmod_if_exists(private_path, 0o600)
    chmod_if_exists(public_path, 0o644)
    return public_path.read_text(encoding="utf-8").strip(), "generated_new_keypair", public_path


def main() -> None:
    if not shutil_which("ssh-keygen"):
        fail("ssh-keygen not found in PATH")

    query = parse_query()
    repo_root = Path(str(query.get("repo_root") or os.getcwd())).resolve()
    private_relpath = str(query.get("private_key_relpath") or ".ssh/id_ed25519_agent_stack")

    public_key, source, public_path = resolve_public_key(repo_root, private_relpath)
    rel_public = os.path.relpath(public_path, repo_root)

    print(
        json.dumps(
            {
                "ssh_public_key": public_key,
                "source": source,
                "public_key_path": rel_public,
            }
        )
    )


def shutil_which(cmd: str) -> Optional[str]:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / cmd
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


if __name__ == "__main__":
    main()
