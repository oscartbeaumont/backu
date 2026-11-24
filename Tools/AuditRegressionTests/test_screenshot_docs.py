#!/usr/bin/env python3
"""Execute the simulator reset prefix from the screenshot regeneration docs.

A disposable simulator is created and deleted. No user simulator or photos are
touched.
"""

from __future__ import annotations

import shutil
import subprocess
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ScreenshotDocumentationTests(unittest.TestCase):
    def test_regenerate_shuts_down_before_erasing(self) -> None:
        if shutil.which("xcrun") is None:
            self.skipTest("xcrun is unavailable")
        readme = (ROOT / "Tools/Screenshots/README.md").read_text()
        regenerate = readme.split("## Regenerate", 1)[1]
        block = regenerate.split("```sh", 1)[1].split("```", 1)[0]
        commands = [
            line.strip()
            for line in block.splitlines()
            if line.strip().startswith("xcrun simctl")
        ]
        first_erase = next(
            index for index, command in enumerate(commands) if " simctl erase " in command
        )
        reset_commands = commands[: first_erase + 1]

        def simctl(*args: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                ["xcrun", "simctl", *args],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )

        name = f"Backu Audit Screenshots {uuid.uuid4().hex[:8]}"
        created = simctl(
            "create",
            name,
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        )
        if created.returncode != 0:
            self.skipTest("required simulator runtime is unavailable: " + created.stdout)
        udid = created.stdout.strip()
        try:
            booted = simctl("boot", udid)
            self.assertEqual(booted.returncode, 0, booted.stdout)
            for command in reset_commands:
                if command.startswith("xcrun simctl shutdown "):
                    result = simctl("shutdown", udid)
                    self.assertEqual(result.returncode, 0, result.stdout)
                elif command.startswith("xcrun simctl erase "):
                    result = simctl("erase", udid)
                    self.assertEqual(
                        result.returncode,
                        0,
                        "documented erase command failed on the booted simulator:\n"
                        + result.stdout,
                    )
        finally:
            simctl("shutdown", udid)
            simctl("delete", udid)


if __name__ == "__main__":
    unittest.main()
