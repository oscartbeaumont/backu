#!/usr/bin/env python3
"""Audit what the mock S3 actually saw, independent of the client's own report.

    python3 Tools/Benchmark/audit_log.py /path/to/mock-9101.log

The mock's request log has one line per request:

    PUT /backu-test/bench/upload/32/new-0.bin?partNumber=3&uploadId=abc -> 200 5242880B sig=ok 12.4ms

This summarises multipart uploads (parts per upload, completed/aborted/orphaned)
and per-key GET/HEAD counts, so a benchmark or UI run can be checked against the
plan it claims to have used. Exit status is 1 when an upload was left dangling.
"""

from __future__ import annotations

import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

LINE = re.compile(
    r"^(?P<method>[A-Z]+) (?P<path>\S+) -> (?P<status>\d{3}) (?P<bytes>\d+)B"
)


def parse(path: Path):
    uploads: dict[str, dict] = {}
    creates = 0
    gets: Counter[str] = Counter()
    heads: Counter[str] = Counter()
    other: Counter[str] = Counter()
    for line in path.read_text(errors="replace").splitlines():
        match = LINE.match(line.strip())
        if not match:
            continue
        method = match["method"]
        status = int(match["status"])
        raw = match["path"]
        raw_path, _, query = raw.partition("?")
        params = {}
        for part in query.split("&"):
            if not part:
                continue
            name, _, value = part.partition("=")
            params[name] = value

        key = raw_path.split("/", 2)[-1] if raw_path.count("/") >= 2 else raw_path
        upload_id = params.get("uploadId")
        if "uploads" in params:
            # CreateMultipartUpload carries no upload id: the id arrives in the
            # response, so it cannot be correlated from the request log alone.
            if 200 <= status < 300:
                creates += 1
            continue
        if upload_id:
            record = uploads.setdefault(
                upload_id, {"key": key, "parts": set(), "bytes": 0, "status": "created"}
            )
            if method == "PUT" and "partNumber" in params:
                if 200 <= status < 300:
                    record["parts"].add(int(params["partNumber"]))
                    record["bytes"] += int(match["bytes"])
            elif method == "POST":
                record["status"] = "completed" if 200 <= status < 300 else "complete-failed"
            elif method == "DELETE":
                record["status"] = "aborted" if 200 <= status < 300 else "abort-failed"
            continue

        if method == "GET":
            gets[key] += 1
        elif method == "HEAD":
            heads[key] += 1
        else:
            other[method] += 1
    return uploads, creates, gets, heads, other


def describe_uploads(uploads: dict[str, dict], creates: int) -> int:
    print(f"multipart: {creates} create request(s)")
    if not uploads:
        return 0
    print("multipart uploads by id:")
    orphans = 0
    for upload_id, record in sorted(uploads.items(), key=lambda item: item[1]["key"]):
        numbers = sorted(record["parts"])
        gaps = ""
        if numbers and numbers != list(range(1, len(numbers) + 1)):
            gaps = " (non-contiguous part numbers)"
        if record["status"] == "created" and record["parts"]:
            orphans += 1
            gaps += "  <-- never completed or aborted"
        print(
            f"  {record['status']:14} {record['key']}: {len(numbers)} part(s) "
            f"{numbers[:3]}{'…' if len(numbers) > 3 else ''} "
            f"{record['bytes'] / (1024 * 1024):.1f} MiB{gaps}"
        )
    return orphans


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    if not path.exists():
        print(f"no such log: {path}")
        return 2
    uploads, creates, gets, heads, other = parse(path)
    orphans = describe_uploads(uploads, creates)
    print("\nGET requests per key (range count = requests here, no HEAD):")
    for key, count in gets.most_common(12):
        print(f"  {count:5}  {key}")
    print("\nHEAD requests per key:")
    for key, count in heads.most_common(12):
        print(f"  {count:5}  {key}")
    if other:
        print("\nother methods:", dict(other))
    if orphans:
        print(f"\n! {orphans} multipart upload(s) left dangling")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
