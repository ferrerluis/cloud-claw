#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "skills/claw-setup/scripts/resolve_do_volume.py"
SPEC = importlib.util.spec_from_file_location("resolve_do_volume", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ResolveDoVolumeTest(unittest.TestCase):
    def test_select_volume_by_name(self) -> None:
        volume = MODULE.select_volume(
            [
                {"id": "vol-1", "name": "alpha", "region": {"slug": "nyc3"}},
                {"id": "vol-2", "name": "beta", "region": {"slug": "sfo3"}},
            ],
            "alpha",
            None,
        )
        self.assertEqual(volume["id"], "vol-1")

    def test_select_volume_by_name_and_region(self) -> None:
        volume = MODULE.select_volume(
            [
                {"id": "vol-1", "name": "alpha", "region": {"slug": "nyc3"}},
                {"id": "vol-2", "name": "alpha", "region": {"slug": "sfo3"}},
            ],
            "alpha",
            "sfo3",
        )
        self.assertEqual(volume["id"], "vol-2")

    def test_rejects_ambiguous_name_without_region(self) -> None:
        with self.assertRaisesRegex(ValueError, "multiple DigitalOcean volumes"):
            MODULE.select_volume(
                [
                    {"id": "vol-1", "name": "alpha", "region": {"slug": "nyc3"}},
                    {"id": "vol-2", "name": "alpha", "region": {"slug": "sfo3"}},
                ],
                "alpha",
                None,
            )


if __name__ == "__main__":
    unittest.main()
