#!/usr/bin/env python3
"""Regression checks for the source sets used by standalone tool scripts.

Run from the repository root:

    python3 -m unittest discover -s Tools/AuditRegressionTests -v

These checks only type-check local Swift sources. They do not start mock servers,
use the network, or generate an Xcode project.
"""

from __future__ import annotations

import glob
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sources(*paths: str) -> list[str]:
    result: list[str] = []
    for path in paths:
        matches = sorted(glob.glob(str(ROOT / path)))
        if not matches:
            raise AssertionError(f"source pattern matched no files: {path}")
        result.extend(str(Path(match).relative_to(ROOT)) for match in matches)
    return result


class StandaloneToolBuildTests(unittest.TestCase):
    def assert_typechecks(self, source_paths: list[str]) -> None:
        result = subprocess.run(
            ["swiftc", "-typecheck", *source_paths],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=180,
        )
        self.assertEqual(
            result.returncode,
            0,
            "standalone tool source set does not compile:\n" + result.stdout,
        )

    def test_atlas_bench_run_source_set_compiles(self) -> None:
        # Keep this list aligned with Tools/AtlasBench/run.sh.
        self.assert_typechecks(
            sources(
                "Sources/Core/Models/StorageProvider.swift",
                "Sources/Core/Models/ServerConfig.swift",
                "Sources/Core/Models/PhotoItem.swift",
                "Sources/Core/Models/Person.swift",
                "Sources/Core/S3/*.swift",
                "Sources/Core/Storage/AppPaths.swift",
                "Sources/Core/Sync/Sidecar.swift",
                "Sources/Core/Library/ThumbnailAtlas.swift",
                "Tools/AtlasBench/main.swift",
            )
        )

    def test_meta_sync_bench_source_set_compiles(self) -> None:
        # Keep this list aligned with Tools/MetaBench/sync.sh.
        self.assert_typechecks(
            sources(
                "Sources/Core/Models/StorageProvider.swift",
                "Sources/Core/Models/ServerConfig.swift",
                "Sources/Core/Models/PhotoItem.swift",
                "Sources/Core/Models/Person.swift",
                "Sources/Core/S3/*.swift",
                "Sources/Core/Storage/AppPaths.swift",
                "Sources/Core/Sync/Sidecar.swift",
                "Sources/Core/Metadata/Gzip.swift",
                "Sources/Core/Metadata/MetadataModels.swift",
                "Sources/Core/Metadata/MergedMetadata.swift",
                "Sources/Core/Metadata/MetadataStore.swift",
                "Sources/Core/Metadata/MetadataService.swift",
                "Sources/Core/Catalog/SearchIndex.swift",
                "Sources/Core/Catalog/CatalogStore.swift",
                "Tools/MetaBench/SyncBench/main.swift",
            )
        )


if __name__ == "__main__":
    unittest.main()
