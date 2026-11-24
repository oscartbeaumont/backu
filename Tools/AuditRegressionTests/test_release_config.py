#!/usr/bin/env python3
"""Local Xcode build-setting checks used by the release scripts."""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ReleaseConfigTests(unittest.TestCase):
    def test_macos_release_does_not_select_an_ios_signing_identity(self) -> None:
        generated = subprocess.run(
            ["xcodegen", "generate"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
        )
        self.assertEqual(generated.returncode, 0, generated.stdout)
        result = subprocess.run(
            [
                "xcodebuild",
                "-project",
                "Backu.xcodeproj",
                "-scheme",
                "Backu",
                "-configuration",
                "Release",
                "-destination",
                "generic/platform=macOS",
                "-showBuildSettings",
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        identities = re.findall(r"^\s*CODE_SIGN_IDENTITY = (.+)$", result.stdout, re.MULTILINE)
        self.assertTrue(identities, result.stdout)
        self.assertFalse(
            any("iPhone" in identity or "iPad" in identity for identity in identities),
            "macOS release selected an iOS signing identity: " + repr(identities),
        )


if __name__ == "__main__":
    unittest.main()
