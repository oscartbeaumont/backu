#!/usr/bin/env python3
"""Offline CLI regression for the standalone transfer benchmark."""

from __future__ import annotations

import glob
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPROVED_TEMP_ROOT = Path("/private/var/folders/ft/fkt3bwqd01g7f54wvyz9wgjc0000gn/T/opencode")
TEMP_ROOT = APPROVED_TEMP_ROOT if APPROVED_TEMP_ROOT.is_dir() else Path(tempfile.gettempdir())


class BenchmarkCLITests(unittest.TestCase):
    def test_negative_size_is_rejected_without_a_trap(self) -> None:
        source_paths = [
            "Sources/Core/Models/StorageProvider.swift",
            "Sources/Core/Models/ServerConfig.swift",
            *sorted(str(Path(p).relative_to(ROOT)) for p in glob.glob(str(ROOT / "Sources/Core/S3/*.swift"))),
            "Tools/Benchmark/main.swift",
        ]
        with tempfile.TemporaryDirectory(prefix="backu-bench-cli-", dir=TEMP_ROOT) as tmp:
            binary = Path(tmp) / "backu-bench"
            build = subprocess.run(
                ["swiftc", "-o", str(binary), *source_paths],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=180,
            )
            self.assertEqual(build.returncode, 0, build.stdout)
            result = subprocess.run(
                [
                    str(binary),
                    "--endpoint",
                    "http://127.0.0.1:1",
                    "--sizes",
                    "-1",
                    "--mode",
                    "baseline",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=10,
            )
            self.assertEqual(
                result.returncode,
                2,
                "negative sizes should produce a usage error, not a signal:\n"
                + result.stdout,
            )
            self.assertIn("positive", result.stdout.lower())


if __name__ == "__main__":
    unittest.main()
