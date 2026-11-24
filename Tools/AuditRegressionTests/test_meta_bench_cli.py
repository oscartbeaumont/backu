#!/usr/bin/env python3
"""Offline correctness checks for the metadata benchmark CLI."""

from __future__ import annotations

import glob
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPROVED_TEMP_ROOT = Path("/private/var/folders/ft/fkt3bwqd01g7f54wvyz9wgjc0000gn/T/opencode")
TEMP_ROOT = APPROVED_TEMP_ROOT if APPROVED_TEMP_ROOT.is_dir() else Path(tempfile.gettempdir())


class MetaBenchCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory(prefix="backu-meta-cli-", dir=TEMP_ROOT)
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "backu-meta-bench"
        source_paths = [
            "Sources/Core/Models/StorageProvider.swift",
            "Sources/Core/Models/ServerConfig.swift",
            "Sources/Core/Models/PhotoItem.swift",
            "Sources/Core/Models/Person.swift",
            *sorted(
                str(Path(path).relative_to(ROOT))
                for path in glob.glob(str(ROOT / "Sources/Core/S3/*.swift"))
            ),
            "Sources/Core/Storage/AppPaths.swift",
            "Sources/Core/Sync/Sidecar.swift",
            "Sources/Core/Metadata/Gzip.swift",
            "Sources/Core/Metadata/MetadataModels.swift",
            "Sources/Core/Metadata/MergedMetadata.swift",
            "Tools/MetaBench/main.swift",
        ]
        result = subprocess.run(
            ["swiftc", "-o", str(cls.binary), *source_paths],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=180,
        )
        if result.returncode != 0:
            raise AssertionError(result.stdout)

    def run_bench(self, *arguments: str) -> tuple[subprocess.CompletedProcess[str], dict]:
        output = Path(self.temp.name) / f"{self._testMethodName}.json"
        result = subprocess.run(
            [
                str(self.binary),
                "--photos",
                "1",
                "--edits",
                "1",
                "--output",
                str(output),
                *arguments,
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
        )
        self.assertTrue(output.exists(), result.stdout)
        return result, json.loads(output.read_text())

    def test_network_failures_make_the_benchmark_fail(self) -> None:
        result, report = self.run_bench("--endpoint", "file:///does-not-exist")
        self.assertNotEqual(
            result.returncode,
            0,
            "all network measurements failed but the benchmark succeeded:\n"
            + result.stdout,
        )
        self.assertEqual(report["uploads"], {})
        self.assertEqual(report["fetches"], {})

    def test_report_uses_the_actual_number_of_edits(self) -> None:
        result, report = self.run_bench(
            "--no-network", "--edits", "100"
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(report["edits"], 1, result.stdout)


if __name__ == "__main__":
    unittest.main()
