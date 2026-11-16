#!/usr/bin/env python3
"""Print a pass 1 vs pass 2 transfer comparison from the benchmark reports.

    python3 Tools/Benchmark/compare.py [results directory]

Both reports must have the same profiles, sizes, warm-ups and measured runs;
the JSON records those values, so a mismatch is reported, not silently compared.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

RESULTS = Path(sys.argv[1] if len(sys.argv) > 1 else "Tools/Benchmark/results")
PROFILES = ["shaped", "localhost", "cellular", "retry"]


def load(path: Path) -> dict | None:
    if not path.exists():
        return None
    with path.open() as handle:
        return json.load(handle)


def index(report: dict) -> dict[tuple[str, str, int], dict]:
    return {
        (scenario["operation"], scenario["mode"], scenario["sizeMB"]): scenario
        for scenario in report["scenarios"]
    }


def change(before: float, after: float) -> str:
    if before <= 0:
        return "n/a"
    return f"{(after - before) / before * 100:+.1f}%"


def plan_text(scenario: dict) -> str:
    part = scenario.get("partSizeBytes")
    concurrency = scenario.get("concurrency")
    if not part or not concurrency:
        return "-"
    return f"{part / (1024 * 1024):.2f} MiB x{concurrency}"


def main() -> int:
    failures = 0
    for profile in PROFILES:
        before = load(RESULTS / f"pass1-{profile}.json")
        after = load(RESULTS / f"pass2-{profile}.json")
        if before is None or after is None:
            continue
        for key in ("sizesMB", "runs", "warmups"):
            if before.get(key) != after.get(key):
                print(f"! {profile}: {key} differs ({before.get(key)} vs {after.get(key)})")
                failures += 1
        old = index(before)
        new = index(after)
        print(f"\n== {profile}  (network {after.get('network', 'n/a')}, {after['runs']} runs, "
              f"{after['warmups']} warm-up)")
        header = (f"{'operation':9} {'size':>6}  {'pass1':>9} {'pass2':>9} {'change':>8}  "
                  f"{'req 1':>5} {'req 2':>5} {'retry 2':>7}  plan")
        print(header)
        print("-" * len(header))
        for (operation, mode, size) in sorted(
            set(old) | set(new), key=lambda k: (k[0], k[2], k[1])
        ):
            if mode != "new":
                continue
            a = old.get((operation, mode, size))
            b = new.get((operation, mode, size))
            if not a or not b:
                continue
            print(
                f"{operation:9} {size:4} MiB  "
                f"{a['medianMegabytesPerSecond']:8.2f}  {b['medianMegabytesPerSecond']:8.2f}  "
                f"{change(a['medianMegabytesPerSecond'], b['medianMegabytesPerSecond']):>8}  "
                f"{a['requests']:5} {b['requests']:5} {b['retries']:7}  {plan_text(b)}"
            )
    print()
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
