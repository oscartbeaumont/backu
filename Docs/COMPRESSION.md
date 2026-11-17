# Compression and streaming: should Backu store something other than the original?

**Verdict: no, not for the originals. Yes, for the previews.**

Backu's job is to keep the bytes the camera produced. The only compression that
is compatible with that promise is lossless recompression, and on today's
iPhone libraries that is worth roughly **1–17 % of the library**, costs a 3.5 MB
encoder and makes every decode ~1.9× slower. The "way more storage efficient"
version of the idea is a lossy re-encode, which turns a backup into a
transcode and sacrifices the one thing Backu promises.

The useful part of the same idea is much smaller and much cheaper: the 900 px
preview objects are **47 % smaller as HEIC than as JPEG** at matched quality,
need no new dependency, and are also the bytes the viewer waits for before it
can paint. That is what this branch implements.

Everything below is reproducible with
[`Tools/CompressionBench`](../Tools/CompressionBench/README.md).

---

## 1. What was actually asked

The request bundles three different things:

1. **Store a compressed form in S3** that is "way more storage efficient".
2. **A stream decoder**, so an image can be rendered while it downloads.
3. **Render without decoding the whole image**, for formats that support it.

They pull in different directions. The JXL modes that keep the archive lossless
cannot also give fine-grained progressive decoding (measured below), and the
third request is already solved by Backu's preview objects for every format,
including the ones that have no progressive mode.

## 2. Method

- Corpus: the public-domain fixtures in `Tests/Fixtures/library`
  (11 photos, 0.3–25.7 MB, 1.3–20 MP), plus HEIC and PNG variants generated
  with Apple's ImageIO encoder so the HEIC numbers come from the same HEVC
  encoder an iPhone uses.
- Codecs: Apple ImageIO (JPEG, HEIC, AVIF, JXL decode on macOS 27 and the
  iOS 26.5 simulator) and the reference tools `cjxl`/`djxl` 0.13.0,
  `avifenc` 1.4.2, `cwebp`, `jpegtran`.
- Speed: warm-up followed by median of 5–15 runs, full decode and 1200 px
  decode, on an Apple-silicon Mac. Absolute phone numbers will be slower; the
  ratios are what matter.
- Every JPEG→JXL lossless claim was checked by reconstructing the JPEG with
  `djxl` and comparing SHA-256. All 11 files round-tripped **bit-exactly**.

## 3. Storage: the honest (lossless) numbers

| Source | Lossless option | Size vs original | Reversible? |
|---|---|---:|---|
| JPEG | JPEG XL lossless transcode (`cjxl -d 0`) | **81.7 %** (71–85 %, n=10) | Yes, original JPEG bitstream reconstructs exactly |
| JPEG | Progressive JPEG (`jpegtran -progressive`) | **92.0 %** (84–94 %) | Pixels/DCT coefficients identical, file bytes differ |
| PNG | JPEG XL lossless modular | **49.8 %** of the PNG (43–52 % on photo PNGs; a real macOS screenshot went to 3.3 %) | Pixel-exact, not PNG-file-exact |
| HEIC | — | **100 %** | HEIC has no lossless recompression; re-encoding its pixels is larger |

The camera already writes HEIC, and HEIC is already close to the entropy limit
for those pixels. A lossless JXL transcode is not available for HEIC at all, so
the dominant format in an iPhone library gets **zero** benefit.

`jpegtran -progressive` is a smaller win but is free of quality risk and needs
no new encoder at decode time. It also streams (see §5).

## 4. Storage: the option that would actually be "way more"

| Codec | Settings | Size vs original | Quality |
|---|---|---:|---|
| JPEG XL | `-d 1.0` (visually lossless) | 50.1 % | lossy |
| JPEG XL | `-d 1.0 -p --progressive_dc=2` | 56.5 % | lossy, streamable |
| AVIF | q80, speed 6 | 49.7 % | lossy |
| HEIC | q70 / q80 | 45.5 % / 57.5 % | lossy |
| WebP | q80 | 24.8 %* | lossy |

\* WebP's median is flattered by PNG sources; on JPEG sources it is 21–50 %.

A 50 % saving is real, but it is a *transcode*, not a backup. It also stacks
generation loss on every re-run, makes the bucket's contents dependent on
Backu's encoder version, and turns "download the original" into "download
Backu's re-encode". That is a different product, not an optimisation.

## 5. Speed: what the codec costs on the device

Decode through ImageIO, median milliseconds:

| Image | JPEG | JXL lossless | JXL lossy (`-d 1`) | HEIC |
|---|---:|---:|---:|---:|
| 4.6 MP portrait | 8.4 | 13.9 (1.7×) | 68.1 (8.2×) | — |
| 24 MP wallpaper | 43.9 | 82.9 (1.9×) | 114.0 (2.6×) | — |
| 2 MP HEIC | — | — | — | 14.5 |
| 24 MP HEIC | — | — | — | 66.8 |

Encoding (Mac, median; a phone is typically 2–4× slower):

| Codec | 20 MP encode |
|---|---:|
| JXL lossless JPEG transcode | 0.36 s |
| JXL lossy `-d 1` | 1.20 s |
| JXL lossy progressive | 1.43 s |
| AVIF q80 | 0.73 s |
| HEIC (hardware) | ~0.1 s |
| JPEG (hardware) | ~0.01 s |

Costs that do not show up in a table: the iOS `libjxl` framework is **3.5 MB**
on arm64, is C++, and has to be built and shipped for both platforms. iOS 26
can *decode* JXL through ImageIO (`public.jpeg-xl`), but it cannot **encode**
it — verified on macOS 27 and the iOS 26.5 simulator — so the encoder is not
optional.

## 6. Streaming: the truth table

"Stream" means the decoder can produce a usable image before the last byte
arrives.

| Format | ImageIO incremental decode | First whole frame in ImageIO | Notes |
|---|---|---|---|
| JPEG baseline | Yes, but only top-down | at 100 % | partial image is a strip, not a frame |
| Progressive JPEG | Yes | 1/8 frame at **1.9–7.4 %** of the file | first DC scan |
| PNG | Yes, top-down | at 100 % | |
| HEIC | **No** | 100 % | ImageIO returns nothing until complete |
| AVIF | **No** | 100 % | |
| JPEG XL | **No** | 100 % | ImageIO has no incremental JXL path |

With libjxl (the only way to get a JXL preview):

| JXL mode | 1/8 preview | 1/4 preview | 1/2 preview | Full |
|---|---:|---:|---:|---:|
| Lossless JPEG transcode (`-d 0`) | 2.3–7.5 % | — | — | 100 % |
| Lossy, not progressive (`-d 1`) | 5.9–18.1 % | — | — | 100 % |
| Lossy + `-p --progressive_dc=2` | 0.1–0.9 % | 0.5–1.4 % | 1.1–2.6 % | 100 % |

That last row is the only genuinely impressive streaming result: a half-size
image after ~1 % of the bytes. It is also **lossy** (56.5 % of the original) and
unavailable through ImageIO, so it needs libjxl on the device and a range-aware
S3 reader. The lossless mode gives a 1/8 preview at 2–12 % — but 1/8 of a 12 MP
photo is 504 px, and the byte cost is already around the 900 px preview Backu
uploads (which is sharper).

**Conclusion:** you can have a lossless archive or a streamable file, not both.
That is the single most important finding in this study.

## 7. The preview pipeline is where the win is

Backu already uploads a 900 px preview per photo and shows it before the
original arrives. That architecture is right. The preview format is not.

Measured at 900 px through ImageIO (median of 10 photos):

| Format | Quality | Size | PSNR | Encode | Decode |
|---|---:|---:|---:|---:|---:|
| JPEG | 0.80 (shipped) | 152.8 KB | 42.6 dB | 2.7 ms | 2.0 ms |
| **HEIC** | **0.80 (this branch)** | **81.7 KB (−47 %)** | **41.6 dB** | **12.6 ms** | **4.1 ms** |
| AVIF | 0.80 | 68.5 KB (−55 %) | 41.6 dB | 102.9 ms | 7.3 ms |

HEIC spends 1.0 dB of PSNR on a *preview* and halves its bytes, using the
hardware HEVC encoder and decoder. AVIF saves another 16 % but costs eight
times the encode CPU and 1.8× the decode CPU; for a background backup that is
the wrong trade. 41.6 dB at 900 px is visually transparent for a placeholder.

Previews are about 8 % of a typical library's bytes, so halving them is a
~4 % total saving — similar to the whole lossless-JXL project on a camera-only
library, with none of the risk.

It also halves the viewer's first-paint payload (153 KB → 82 KB). The bigger
viewer win is not a codec at all: `ViewerPager.ensureLoading()` downloads the
**full original** as soon as a page becomes current, even though a fit-to-screen
view is 1200 px. On the 24 MP wallpaper in the corpus a view costs a 161 KB
preview + a 10.1 MB original; a HEIC preview is 109 KB, so deferring the
original until the user zooms turns that into 109 KB — 94× less data for every
photo opened and not zoomed. JXL lossless would have made the same view
8.35 MB, a 19 % saving. That change is intentionally out of scope here (it
changes viewer behaviour and its tests), but it is the next thing worth doing if
bandwidth or time-to-sharp matters more than storage.

## 8. What it means for a real library

Model with 5,000 photos: 70 % HEIC at 1.8 MB, 20 % JPEG at 2.5 MB, 10 % PNG at
2.0 MB, plus one 900 px preview each. Sizes are stated assumptions; ratios are
measured.

| Composition | Library | JXL lossless | HEIC previews | Both |
|---|---:|---:|---:|---:|
| Camera-only (95 % HEIC) | 8.96 GB | 1.2 % | 3.8 % | **5.0 %** |
| Typical (70/20/10) | 9.57 GB | 9.8 % | 3.5 % | **13.3 %** |
| Import-heavy (30/60/10) | 10.94 GB | 16.7 % | 3.1 % | **19.8 %** |

The JXL column is entire-library bytes, not JPEG bytes. It is large only
because PNG screenshots compress so well. A camera-only library — the common
case for an iPhone backup — gets almost nothing.

## 9. Decision

| Option | Saving | New dependency | Decode penalty | Risk | Verdict |
|---|---:|---|---|---|---|
| JXL lossless for JPEG/PNG originals | 1–17 % | 3.5 MB libjxl, encoder + decoder | 1.9× | bucket interop (iOS <18.2, most non-Apple tools), byte-exactness needs libjxl | **No** |
| Lossy JXL/AVIF/HEIC originals | ~50 % | libjxl / AVIF encoder | 2.6–8× | destroys the backup promise | **No** |
| Progressive JPEG originals | 8 % | JPEG transcoder | none | pixels identical, file bytes differ | Maybe later |
| **HEIC previews** | **3.1–3.8 %** | **none (ImageIO)** | 2× preview decode (4 ms) | old clients already read HEIC | **Yes — implemented** |
| Defer the original until zoom | 95 % of viewer bytes | none | none | UX change | Recommended next |

## 10. What this branch changes

- `PreviewCodec` writes previews as HEIC when ImageIO can, JPEG otherwise, and
  is the only place that knows the format.
- `BackupEngine` uploads `.backu/thumbs/<hash>.heic` with `image/heic`.
- `RemoteAssetLoader` derives the cache extension from the stored key, so
  buckets with old `.jpg` previews and new `.heic` previews both work; old app
  versions can still read the new objects because they decode through ImageIO.
- Tests cover the round trip, the size win over JPEG, the fallback, and
  extension parsing.
- `Tools/CompressionBench` reproduces every table above.
- JXL objects already decode natively on iOS 26 / macOS 26 through ImageIO, so
  a bucket that contains JXL (written by another tool) needs no extra code;
  `UTTypeShim` maps `public.jpeg-xl` to `image/jxl` and `.jxl`.

## 11. Reproduce

```sh
# fixtures (public domain; not committed)
swift Tools/Fixtures/prepare-fixtures.swift

brew install jpeg-xl libavif webp jpeg-turbo   # optional, for the codec matrix
python3 Tools/CompressionBench/bench.py --limit 12
```

The harness writes `Tools/CompressionBench/results/previews.csv`,
`originals.csv` and `summary.md`. See the tool's README for the streaming
probes and the iOS simulator commands.
