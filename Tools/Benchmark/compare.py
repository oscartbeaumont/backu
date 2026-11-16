#!/usr/bin/env python3
"""Print a transfer comparison between two benchmark passes.

    python3 Tools/Benchmark/compare.py                       # pass2 -> pass3
    python3 Tools/Benchmark/compare.py --from pass1 --to pass2
    python3 Tools/Benchmark/compare.py --results DIR --from pass1 --to pass3

Both reports must have the same profiles, sizes, warm-ups and measured runs;
the JSON records those values, so a mismatch is reported, not silently compared.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PROFILES = ["shaped", "localhost", "cellular", "retry"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "results_directory",
        nargs="?",
        default="Tools/Benchmark/results",
        help="directory holding the pass JSON reports",
    )
    parser.add_argument("--results", dest="results", help="same as results_directory")
    parser.add_argument("--from", dest="before", default="pass2", help="baseline pass prefix")
    parser.add_argument("--to", dest="after", default="pass3", help="new pass prefix")
    return parser.parse_args()


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
    text = f"{part / (1024 * 1024):.2f}MiB x{concurrency}"
    count = scenario.get("partCount")
    if count:
        text += f"/{count}"
    return text


def memory_text(scenario: dict) -> str:
    peak = scenario.get("peakFootprintBytes")
    if not peak:
        return "-"
    return f"{peak / (1024 * 1024):.0f}MiB"


def main() -> int:
    args = parse_args()
    results = Path(args.results or args.results_directory)
    failures = 0
    for profile in PROFILES:
        before = load(results / f"{args.before}-{profile}.json")
        after = load(results / f"{args.after}-{profile}.json")
        if before is None or after is None:
            continue
        for key in ("sizesMB", "runs", "warmups"):
            if before.get(key) != after.get(key):
                print(f"! {profile}: {key} differs ({before.get(key)} vs {after.get(key)})")
                failures += 1
        old = index(before)
        new = index(after)
        print(
            f"\n== {profile}  (network {after.get('network', 'n/a')}, {after['runs']} runs, "
            f"{after['warmups']} warm-up)"
        )
        header = (
            f"{'operation':9} {'size':>6}  {args.before:>9} {args.after:>9} {'change':>8}  "
            f"{'req~':>5} {'req+':>5} {'retry':>6}  "
            f"{'plan~':>15} {'plan+':>15}  {'peak':>7}"
        )
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
                f"{a['requests']:5} {b['requests']:5} {b['retries']:6}  "
                f"{plan_text(a):>15} {plan_text(b):>15}  {memory_text(b):>7}"
            )
            if size >= 32 and operation in {"upload", "download"}:
                delta = (
                    (b["medianMegabytesPerSecond"] - a["medianMegabytesPerSecond"])
                    / a["medianMegabytesPerSecond"]
                    if a["medianMegabytesPerSecond"]
                    else 0
                )
                if profile == "shaped" and delta < 0.15:
                    print(
                        f"    ! {profile} {size} MiB {operation} is {delta * 100:+.1f}%, "
                        "below the 15% target"
                    )
        if after.get("partSizeMB") or after.get("concurrency"):
            print(
                f"  (forced: partSizeMB={after.get('partSizeMB')} "
                f"concurrency={after.get('concurrency')})"
            )
    print()
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
