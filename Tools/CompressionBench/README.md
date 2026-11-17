# Compression benchmark

Reproduces the study in [`Docs/COMPRESSION.md`](../../Docs/COMPRESSION.md).

It measures the things a published codec comparison cannot tell you: what
Apple's ImageIO actually decodes and encodes on the OS versions Backu targets,
how fast, and how much of a file must arrive before an image can be painted.

## Quick start

```sh
swift Tools/Fixtures/prepare-fixtures.swift      # public-domain fixtures, not committed
python3 Tools/CompressionBench/bench.py --limit 12
```

Optional codec CLIs (the harness reports and skips anything missing):

```sh
brew install jpeg-xl libavif webp jpeg-turbo
```

Results land in `results/`:

- `previews.csv` — every 900 px JPEG/HEIC/AVIF preview: bytes, PSNR against the
  lossless downscale, encode and decode milliseconds.
- `originals.csv` — per-file size and encode time for JXL
  lossless/lossy/progressive, AVIF, WebP, HEIC and progressive JPEG, plus
  PNG→JXL lossless.
- `summary.md` — the aggregated tables that go into the doc.

`bench.py` also prints the library projection at the end. The composition
assumptions are stated in the source; the ratios come from the corpus.

## What each command measures

The Swift tool is standalone (no SPM, no app sources) so it hits the same
ImageIO code paths as the app:

```sh
swiftc -O -o /tmp/backu-compression Tools/CompressionBench/main.swift

/tmp/backu-compression formats                  # encode/decode support per type
/tmp/backu-compression thumbs /tmp/out 900 a.jpg b.heic
/tmp/backu-compression decode a.jpg b.heic      # full and 1200 px decode
/tmp/backu-compression stream a.jpg b.heic      # incremental decode offsets
/tmp/backu-compression psnr a.avif ref.png
```

`stream` feeds a file to `CGImageSourceCreateIncremental` in chunks and prints
the percentage at which an image first comes back, at which an image can be
produced at 1200 px, and when the source reports complete. A format that prints
`never` is all-or-nothing: a range downloader buys nothing.

## JPEG XL streaming probe

ImageIO has no incremental JXL path, so the only way to see JXL's progressive
behaviour is libjxl's own decoder:

```sh
cc -O2 -I$(brew --prefix jpeg-xl)/include Tools/CompressionBench/jxl_stream_probe.c \
   -L$(brew --prefix jpeg-xl)/lib -ljxl -o /tmp/jxl_stream_probe

/tmp/jxl_stream_probe photo.jxl        # stop after a 1/2-scale preview
```

It prints the byte offset of each `JXL_DEC_FRAME_PROGRESSION` and the intended
downsampling ratio. Compare:

```sh
cjxl -d 0 photo.jpg lossless.jxl                     # archive copy
cjxl --lossless_jpeg=0 -d 1.0 -p --progressive_dc=2 photo.jpg stream.jxl
```

The lossless transcode offers a 1/8 preview after a few percent of the file and
nothing finer; the progressive mode offers 1/2 after ~1 % but is lossy. That is
the trade-off the document is about.

## iOS availability

The deployment target is iOS 26, and macOS ImageIO is not proof of what the
phone framework does. Build the same probe for the simulator and run it there:

```sh
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swiftc -O -target arm64-apple-ios26.5-simulator -sdk "$SDK" \
  Tools/CompressionBench/main.swift -o /tmp/backu-compression-ios
xcrun simctl spawn booted /tmp/backu-compression-ios formats
```

`formats` is the authoritative answer for `public.jpeg-xl` (decode-only in
iOS 26) and `public.avif` (encode and decode). Decode timings in the simulator
run on the host CPU, so treat them as an ordering, not a phone benchmark.

## JPEG scans

`bench.py` parses progressive JPEG scan boundaries itself (`jpeg_scans`), which
gives the byte offset where the first whole-frame DC scan ends. That is the
progressive-JPEG streaming cost, without relying on decoder-specific APIs.

## Caveats

- The fixture corpus is public-domain portraits and dogs, not a real photo
  library. It spans 1.3–20 MP and roughly the right mix of detail, but the
  per-image ratios vary by ±6 points. The document quotes medians and ranges.
- HEIC/PNG variants are encoded by ImageIO on the host. That is the same HEVC
  encoder family as the phone, but a camera pipeline also denoises and
  sharpens, so a camera HEIC may compress slightly differently.
- Encode times are single-run samples on an Apple-silicon Mac. A phone is
  slower; the relative costs are the useful part.
