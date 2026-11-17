#!/usr/bin/env python3
"""Reproducible compression study for Backu.

Measures, on the machine that runs it:

  * preview (thumbnail) size, quality and speed for JPEG / HEIC / AVIF
  * original size and encode speed for JXL lossless/lossy/progressive,
    AVIF, WebP, HEIC and progressive JPEG
  * ImageIO decode speed for every format
  * how much of a file must arrive before ImageIO can decode an image
  * how much of a JPEG XL file a streaming decoder needs for 1/8..1/2 previews
  * what all of that means for a realistic photo library

External codec CLIs are optional; missing ones are reported and skipped:
  cjxl, djxl, avifenc, cwebp, jpegtran  (brew install jpeg-xl libavif webp jpeg-turbo)

Usage:
  python3 Tools/CompressionBench/bench.py
  python3 Tools/CompressionBench/bench.py --corpus /path/to/photos --limit 20
"""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from collections import defaultdict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BENCH = os.path.join(tempfile.gettempdir(), "backu-compression")
RESULTS = os.path.join(ROOT, "Tools", "CompressionBench", "results")


def run(command, cwd=None):
    started = time.perf_counter()
    proc = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    return proc.returncode == 0, time.perf_counter() - started, proc


def have(tool):
    return shutil.which(tool) is not None


def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return None


def build_swift_tool():
    os.makedirs(BENCH, exist_ok=True)
    binary = os.path.join(BENCH, "backu-compression")
    ok, _, proc = run([
        "swiftc", "-O", "-o", binary,
        os.path.join(ROOT, "Tools", "CompressionBench", "main.swift"),
    ])
    if not ok:
        sys.exit(proc.stderr)
    return binary


def build_jxl_probe():
    prefix = subprocess.run(["brew", "--prefix", "jpeg-xl"], capture_output=True, text=True).stdout.strip()
    if not prefix or not os.path.isdir(os.path.join(prefix, "include", "jxl")):
        return None
    binary = os.path.join(BENCH, "jxl_stream_probe")
    ok, _, _ = run([
        "cc", "-O2", f"-I{prefix}/include",
        os.path.join(ROOT, "Tools", "CompressionBench", "jxl_stream_probe.c"),
        f"-L{prefix}/lib", "-ljxl", "-o", binary,
    ])
    return binary if ok else None


def corpus(paths, limit):
    files = []
    for path in paths:
        if os.path.isdir(path):
            for name in sorted(os.listdir(path)):
                if name.lower().endswith((".jpg", ".jpeg", ".heic", ".png")):
                    files.append(os.path.join(path, name))
        elif os.path.isfile(path):
            files.append(path)
    # Prefer larger originals: compression ratios on 30 KB fixtures are noise.
    files.sort(key=lambda p: os.path.getsize(p), reverse=True)
    if limit:
        files = files[:limit]
    return files


def jpeg_scans(path):
    data = open(path, "rb").read()
    i, n = 2, len(data)
    scans = []
    while i < n - 1:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        i += 2
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            continue
        if marker == 0xD9 or i + 2 > n:
            break
        length = (data[i] << 8) | data[i + 1]
        if marker == 0xDA:
            start = i - 2
            j = i + length
            while j < n - 1:
                if data[j] == 0xFF:
                    k = data[j + 1]
                    if k == 0x00 or 0xD0 <= k <= 0xD7:
                        j += 2
                        continue
                    break
                j += 1
            scans.append((start, j))
            i = j
            continue
        i += length
    return len(data), scans


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", nargs="+", default=[os.path.join(ROOT, "Tests", "Fixtures", "library")])
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--max-pixel", type=int, default=900)
    parser.add_argument("--skip-slow", action="store_true", help="skip AVIF/WebP/JXL encode matrix")
    args = parser.parse_args()

    os.makedirs(BENCH, exist_ok=True)
    os.makedirs(RESULTS, exist_ok=True)
    files = corpus(args.corpus, args.limit)
    if not files:
        sys.exit("no corpus files found; run Tools/Fixtures/prepare-fixtures.swift first")

    tool = build_swift_tool()
    jxl_probe = build_jxl_probe()
    enc = os.path.join(BENCH, "encoded")
    os.makedirs(enc, exist_ok=True)

    print(f"corpus: {len(files)} files, {sum(size(f) for f in files)/1e6:.1f} MB")
    print(f"codecs: cjxl={have('cjxl')} avifenc={have('avifenc')} cwebp={have('cwebp')} "
          f"jpegtran={have('jpegtran')} libjxl-probe={bool(jxl_probe)}")

    # 1. What this OS can do.
    formats = subprocess.run([tool, "formats"], capture_output=True, text=True).stdout
    print("\n== ImageIO formats ==")
    print(formats.strip())

    # 2. Preview matrix.
    print("\n== Previews (900 px) ==")
    proc = subprocess.run([tool, "thumbs", os.path.join(BENCH, "thumbs"),
                           str(args.max_pixel)] + files, capture_output=True, text=True)
    preview_rows = list(csv.DictReader(proc.stdout.splitlines(), delimiter="\t"))
    preview_rows = [r for r in preview_rows if r.get("bytes")]
    if not preview_rows:
        sys.exit("preview encoding produced no rows")
    with open(os.path.join(RESULTS, "previews.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(preview_rows[0].keys()))
        writer.writeheader()
        writer.writerows(preview_rows)
    preview_summary = print_preview_summary(preview_rows)

    # 3. Original-format matrix.
    print("\n== Originals ==")
    original_rows = encode_matrix(files, enc, args.skip_slow)
    with open(os.path.join(RESULTS, "originals.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(original_rows[0].keys()))
        writer.writeheader()
        writer.writerows(original_rows)
    print_original_summary(original_rows)

    # 4. Decode timings for the formats that matter.
    variants = [
        os.path.join(enc, os.path.basename(f) + ".jxl.ll.jxl") for f in files
    ] + [
        os.path.join(enc, os.path.basename(f) + ".jxl.d1.jxl") for f in files
    ] + files
    variants = [v for v in variants if os.path.exists(v)]
    print("\n== Decode (ImageIO) ==")
    proc = subprocess.run([tool, "decode"] + variants, capture_output=True, text=True)
    decode_rows = list(csv.DictReader(proc.stdout.splitlines(), delimiter="\t"))
    print(f"{'format':10} {'files':>5} {'full ms':>9} {'1200px ms':>11}")
    by_type = defaultdict(list)
    for row in decode_rows:
        if "full_ms" not in row:
            continue
        by_type[row["type"]].append((float(row["full_ms"]), float(row["thumb1200_ms"])))
    for kind, values in sorted(by_type.items()):
        print(f"{kind:10} {len(values):5d} {statistics.median(v[0] for v in values):9.2f} "
              f"{statistics.median(v[1] for v in values):11.2f}")

    # 5. Streaming: ImageIO incremental support.
    print("\n== ImageIO incremental decode (bytes needed for an image) ==")
    probe_files = []
    for f in files[:3]:
        base = os.path.join(enc, os.path.basename(f))
        for candidate in (f, base + ".prog.jpg", base + ".jxl.ll.jxl", base + ".jxl.d1p.jxl"):
            if os.path.exists(candidate):
                probe_files.append(candidate)
        heic = os.path.join(enc, os.path.basename(f) + ".heic80.heic")
        if os.path.exists(heic):
            probe_files.append(heic)
    proc = subprocess.run([tool, "stream"] + probe_files, capture_output=True, text=True)
    print(proc.stdout.strip())

    # 6. Streaming: JPEG scans and JXL progression.
    print("\n== Progressive JPEG scans ==")
    for f in files[:3]:
        progressive = os.path.join(enc, os.path.basename(f) + ".prog.jpg")
        if not os.path.exists(progressive):
            continue
        total, scans = jpeg_scans(progressive)
        baseline = size(f)
        if not scans:
            continue
        first_scan_end = scans[0][1]
        print(f"{os.path.basename(f):24} baseline={baseline:>9} progressive={total:>9} "
              f"({100*total/baseline:5.1f}%) first-scan-end={100*first_scan_end/total:5.1f}% "
              f"({first_scan_end} bytes, 1/8 frame)")

    if jxl_probe:
        print("\n== JPEG XL streaming (libjxl) ==")
        for f in files[:3]:
            for suffix in (".jxl.ll.jxl", ".jxl.d1.jxl", ".jxl.d1p.jxl"):
                path = os.path.join(enc, os.path.basename(f) + suffix)
                if not os.path.exists(path):
                    continue
                try:
                    proc = subprocess.run([jxl_probe, path, "2"], capture_output=True, text=True, timeout=30)
                except subprocess.TimeoutExpired:
                    print(f"{os.path.basename(path)}: timeout")
                    continue
                lines = [line.strip() for line in proc.stdout.splitlines()
                         if "preview" in line or "full image" in line]
                print(f"{os.path.basename(path)}: " + "; ".join(lines))

    # 7. Library model.
    print("\n== Library model ==")
    library_model(original_rows, preview_rows)

    write_markdown(preview_summary, original_rows, preview_rows)
    print(f"\nwrote {RESULTS}/previews.csv, originals.csv, summary.md")


def print_preview_summary(rows):
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["format"], row["quality"])].append(row)
    print(f"{'format':7} {'quality':>7} {'median KB':>10} {'PSNR dB':>8} {'encode ms':>10} {'decode ms':>10}")
    summary = {}
    for (fmt, quality), values in sorted(grouped.items()):
        kb = statistics.median(int(v["bytes"]) for v in values) / 1024
        psnr = statistics.median(float(v["psnr"]) for v in values)
        encode = statistics.median(float(v["encode_ms"]) for v in values)
        decode = statistics.median(float(v["decode_ms"]) for v in values)
        summary[(fmt, quality)] = (kb, psnr, encode, decode)
        print(f"{fmt:7} {quality:>7} {kb:10.1f} {psnr:8.2f} {encode:10.1f} {decode:10.1f}")
    return summary


def encode_matrix(files, out_dir, skip_slow):
    rows = []
    tools = {
        "jxl-lossless": ["cjxl", "-d", "0", "-e", "7"],
        "jxl-lossy": ["cjxl", "--lossless_jpeg=0", "-d", "1.0", "-e", "7"],
        "jxl-progressive": ["cjxl", "--lossless_jpeg=0", "-d", "1.0", "-e", "7", "-p", "--progressive_dc=2"],
        "avif-q80": ["avifenc", "-q", "80", "--speed", "6", "-j", "all"],
        "webp-q80": ["cwebp", "-quiet", "-q", "80"],
        "jpeg-progressive": ["jpegtran", "-progressive", "-copy", "all"],
    }
    for path in files:
        base = os.path.join(out_dir, os.path.basename(path))
        original = size(path)
        rows.append({"source": os.path.basename(path), "codec": "original",
                     "bytes": original, "ratio": 1.0, "encode_s": 0.0})
        is_jpeg = path.lower().endswith((".jpg", ".jpeg"))
        for codec, command in tools.items():
            if skip_slow and codec.startswith(("avif", "webp")):
                continue
            if codec.startswith("jxl") and not is_jpeg:
                continue  # JXL lossless is a JPEG transcode; PNG/HEIC need another study
            if codec == "jpeg-progressive" and not is_jpeg:
                continue
            if not have(command[0]):
                continue
            suffixes = {
                "jxl-lossless": ".jxl.ll.jxl",
                "jxl-lossy": ".jxl.d1.jxl",
                "jxl-progressive": ".jxl.d1p.jxl",
                "avif-q80": ".avif",
                "webp-q80": ".webp",
                "jpeg-progressive": ".prog.jpg",
            }
            target = base + suffixes[codec]
            if codec == "jpeg-progressive":
                ok, seconds, _ = run(command + ["-outfile", target, path])
            else:
                ok, seconds, _ = run(command + [path, target])
            if not ok or not size(target):
                continue
            rows.append({"source": os.path.basename(path), "codec": codec,
                         "bytes": size(target), "ratio": size(target) / original,
                         "encode_s": round(seconds, 3)})
        # PNG sources are a separate lossless case (screenshots, exports).
        if is_jpeg and have("cjxl") and have("sips"):
            png = base + ".png.png"
            ok, _, _ = run(["sips", "-s", "format", "png", path, "--out", png])
            if ok and size(png):
                target = base + ".png.jxl.ll.jxl"
                ok, seconds, _ = run(["cjxl", "-d", "0", "-e", "7", png, target])
                if ok and size(target):
                    rows.append({"source": os.path.basename(path), "codec": "jxl-lossless-png",
                                 "bytes": size(target), "ratio": size(target) / size(png),
                                 "encode_s": round(seconds, 3)})
        for quality in (70, 80):
            if not have("sips"):
                continue
            target = base + f".heic{quality}.heic"
            ok, seconds, _ = run(["sips", "-s", "format", "heic", "-s", "formatOptions",
                                  str(quality), path, "--out", target])
            if ok and size(target):
                rows.append({"source": os.path.basename(path), "codec": f"heic-q{quality}",
                             "bytes": size(target), "ratio": size(target) / original,
                             "encode_s": round(seconds, 3)})
    return rows


def print_original_summary(rows):
    grouped = defaultdict(list)
    for row in rows:
        if row["codec"] != "original":
            grouped[row["codec"]].append(row)
    print(f"{'codec':20} {'n':>3} {'median of original':>20} {'encode s':>9}")
    for codec, values in sorted(grouped.items()):
        ratios = [float(v["ratio"]) for v in values]
        seconds = [float(v["encode_s"]) for v in values]
        print(f"{codec:20} {len(ratios):3d} {100*statistics.median(ratios):19.1f}% "
              f"{statistics.median(seconds):9.2f}")


def library_model(original_rows, preview_rows):
    """Project the measured ratios onto a stated, typical library."""
    def ratio(codec):
        values = [float(r["ratio"]) for r in original_rows if r["codec"] == codec and r["ratio"]]
        return statistics.median(values) if values else None

    jxl_jpeg = ratio("jxl-lossless")
    jpeg_prog = ratio("jpeg-progressive")

    # Medians from the 900 px preview matrix.
    def preview_kb(fmt, quality):
        values = [int(r["bytes"]) for r in preview_rows if r["format"] == fmt and r["quality"] == quality]
        return statistics.median(values) / 1024 if values else 0

    jpeg_preview = preview_kb("jpeg", "0.80")
    heic_preview = preview_kb("heic", "0.80")

    # Stated assumptions, not measurements: an iPhone library is mostly HEIC,
    # with JPEG imports and PNG screenshots. Sizes are typical 12 MP exports.
    compositions = {
        "camera-only": {"heic": (0.95, 1.8), "jpeg": (0.05, 2.5), "png": (0.00, 2.0)},
        "typical": {"heic": (0.70, 1.8), "jpeg": (0.20, 2.5), "png": (0.10, 2.0)},
        "import-heavy": {"heic": (0.30, 1.8), "jpeg": (0.60, 2.5), "png": (0.10, 2.0)},
    }
    print("Assumptions: HEIC 1.8 MB, JPEG 2.5 MB, PNG 2.0 MB; 900 px preview per photo.")
    print(f"Measured: JXL lossless JPEG ratio "
          f"{jxl_jpeg:.3f}" if jxl_jpeg else "Measured: JXL lossless unavailable",
          f"progressive JPEG {jpeg_prog:.3f}" if jpeg_prog else "",
          f"preview JPEG {jpeg_preview:.0f} KB -> HEIC {heic_preview:.0f} KB")
    jxl_jpeg = jxl_jpeg or 1.0
    print(f"{'composition':14} {'library GB':>11} {'JXL lossless':>13} {'HEIC previews':>14} {'both':>8}")
    for name, parts in compositions.items():
        photos = 5000
        by_class = {kind: (share * photos, mb) for kind, (share, mb) in parts.items()}
        total = sum(count * mb for count, mb in by_class.values())  # MB
        # Only JPEG is losslessly recompressed; PNG needs its own encoder path
        # and HEIC has no lossless recompression at all.
        png_jxl = ratio("jxl-lossless-png") or 1.0
        jxl_saving = by_class["jpeg"][0] * by_class["jpeg"][1] * (1 - jxl_jpeg)
        jxl_saving += by_class["png"][0] * by_class["png"][1] * (1 - png_jxl)
        preview_before = photos * jpeg_preview / 1024
        preview_after = photos * heic_preview / 1024
        preview_saving = preview_before - preview_after
        both = jxl_saving + preview_saving
        print(f"{name:14} {total/1024:11.2f} {jxl_saving/total*100:12.1f}% "
              f"{preview_saving/total*100:13.1f}% {both/total*100:7.1f}%")


def write_markdown(preview_summary, original_rows, preview_rows):
    lines = ["# Compression benchmark results", "",
             "Generated by `Tools/CompressionBench/bench.py`.", "",
             "## Previews (900 px, ImageIO)", "",
             "| format | quality | median KB | PSNR dB | encode ms | decode ms |",
             "|---|---|---|---|---|---|"]
    for (fmt, quality), (kb, psnr, encode, decode) in sorted(preview_summary.items()):
        lines.append(f"| {fmt} | {quality} | {kb:.1f} | {psnr:.2f} | {encode:.1f} | {decode:.1f} |")

    grouped = defaultdict(list)
    for row in original_rows:
        if row["codec"] != "original":
            grouped[row["codec"]].append(row)
    lines += ["", "## Originals", "", "| codec | n | median of original | encode s |", "|---|---|---|---|"]
    for codec, values in sorted(grouped.items()):
        lines.append(f"| {codec} | {len(values)} | "
                     f"{100*statistics.median(float(v['ratio']) for v in values):.1f}% | "
                     f"{statistics.median(float(v['encode_s']) for v in values):.2f} |")
    lines += ["", "See `Docs/COMPRESSION.md` for interpretation and the recommendation.", ""]
    with open(os.path.join(RESULTS, "summary.md"), "w") as handle:
        handle.write("\n".join(lines))


if __name__ == "__main__":
    main()
