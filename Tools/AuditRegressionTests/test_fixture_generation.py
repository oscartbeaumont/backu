#!/usr/bin/env python3
"""Offline regressions for required simulator fixture generation."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPROVED_TEMP_ROOT = Path("/private/var/folders/ft/fkt3bwqd01g7f54wvyz9wgjc0000gn/T/opencode")
TEMP_ROOT = APPROVED_TEMP_ROOT if APPROVED_TEMP_ROOT.is_dir() else Path(tempfile.gettempdir())


class FixtureGenerationTests(unittest.TestCase):
    def test_prepare_fixtures_fails_when_required_sources_are_missing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="backu-fixtures-", dir=TEMP_ROOT) as tmp:
            work = Path(tmp)
            (work / "Tests/Fixtures/raw").mkdir(parents=True)
            result = subprocess.run(
                ["swift", str(ROOT / "Tools/Fixtures/prepare-fixtures.swift")],
                cwd=work,
                env={**os.environ, "TMPDIR": str(work)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=180,
            )
            self.assertNotEqual(
                result.returncode,
                0,
                "missing required source photos must fail fixture preparation:\n"
                + result.stdout,
            )

    def test_download_fixtures_fails_when_every_download_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="backu-fixture-download-", dir=TEMP_ROOT) as tmp:
            work = Path(tmp)
            scripts = work / "Tools/Fixtures"
            scripts.mkdir(parents=True)
            shutil.copy2(ROOT / "Tools/Fixtures/download-fixtures.sh", scripts)
            fake_bin = work / "bin"
            fake_bin.mkdir()
            for name, body in {
                "curl": "#!/bin/sh\nexit 1\n",
                # Keep the retry test fast; no real sleeping is needed.
                "sleep": "#!/bin/sh\nexit 0\n",
            }.items():
                tool = fake_bin / name
                tool.write_text(body)
                tool.chmod(0o755)

            result = subprocess.run(
                ["bash", str(scripts / "download-fixtures.sh")],
                cwd=work,
                env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
            )
            self.assertNotEqual(
                result.returncode,
                0,
                "failed fixture downloads must fail the download step:\n"
                + result.stdout,
            )


if __name__ == "__main__":
    unittest.main()
