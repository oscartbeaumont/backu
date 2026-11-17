# Thumbnail atlas benchmark

A standalone Swift CLI compiled against the app's real encoder, decoder and S3
client. It answers one question: **is packing remote thumbnails into sprite
sheets worth the sync complexity?**

It measures three things:

1. **Bytes per tile** for individual JPEGs and for atlas sheets at several cell
   sizes and codecs (JPEG, HEIC, AVIF), on real photographs.
2. **Encode and decode cost** on the machine that has to do the work: the phone
   encoding at upload time, and the phone decoding 36 tiles from one sheet.
3. **End-to-end time to paint a scroll**, replaying the grid's request pattern
   against a shaped mock bucket, so request count, latency and bytes all count.

## Run it

```sh
./Tools/AtlasBench/run.sh
```

That builds `/tmp/backu-atlas-bench`, expands the real fixture photos into 300
deterministic crops (`Tests/Fixtures/atlas-corpus`, git-ignored) so codec sizes
are measured on photographic entropy rather than the synthetic gradients in
`Tests/Fixtures/performance/library`, and writes:

```
Tools/AtlasBench/results/pass1-encode.json      bytes, PSNR-adjacent encode/decode matrix
Tools/AtlasBench/results/pass1-shaped.json      25 ms RTT, 60 Mbps per connection
Tools/AtlasBench/results/pass1-mobile.json      80 ms RTT,  8 Mbps per connection
Tools/AtlasBench/results/pass1-localhost.json   no shaping (wire-cost floor)
```

The shaped profiles use the same mock (`Tools/MockS3/mock_s3.py`) and the same
per-connection token bucket as `Tools/Benchmark`, so the two reports are
comparable.

Useful overrides:

```sh
BACKU_ATLAS_PHOTOS=300 BACKU_ATLAS_RUNS=3 ./Tools/AtlasBench/run.sh
BACKU_ATLAS_PASS=pass2 ./Tools/AtlasBench/run.sh
```

## What the corpus is (and is not)

The scroll fixtures are generated gradients, which every codec compresses far
too well. The benchmark instead takes the 17 real photographs in
`Tests/Fixtures/raw` and `Tests/Fixtures/marketing/raw`, renders 300 overlapping
1600 px square crops at quality 0.92, and shuffles them so a "first screen" is
not 15 crops of one face. That gives realistic high-frequency detail at the
cost of repeated subjects. Bytes per tile are representative; per-tile variance
across a real library is larger.

## Results

300 photos, 36 tiles per sheet, one warm-up and three measured runs.
`current` is what the app ships: one 900 px, quality 0.8 JPEG per photo.
`grid` and `preview` are atlas levels (HEIC q0.62 at 384 px, HEIC q0.50 at 64 px).

### Bytes per tile

| strategy | B/tile | vs current | 100k-photo library |
| --- | ---: | ---: | ---: |
| current 900 px JPEG q0.8 | 183,712 | 1.0× | **18.4 GB** |
| individual 384 px JPEG q0.62 | 28,428 | 6.5× smaller | 2.84 GB |
| grid atlas 384 px HEIC q0.62 | 17,426 | 10.5× smaller | **1.74 GB** |
| preview atlas 64 px HEIC q0.50 | 666 | 276× smaller | **67 MB** |

Codec sweep on a diverse 36-tile sample (bytes per tile, mean PSNR against the
source tile):

| codec | 384 px | PSNR | 64 px | PSNR |
| --- | ---: | ---: | ---: | ---: |
| JPEG q0.62 | 25.1 KB | 40.3 dB | 1.22 KB | 35.1 dB |
| HEIC q0.62 | 15.3 KB | 39.7 dB | 858 B | 34.6 dB |
| AVIF q0.62 | 12.4 KB | 39.2 dB | 767 B | 34.7 dB |

HEIC saves ~40% of the bytes at within 0.6 dB of JPEG. AVIF saves ~50% but is
another 1.1 dB down, and both encodes and decodes in software on every scroll;
HEIC is hardware on Apple platforms. The app therefore uses HEIC. (ImageIO
cannot *encode* WebP on Apple platforms, so it was not a candidate. PSNR is
sampled separately from the byte table above, on a different diverse 36-tile
sample.)

Encode and decode cost, per tile, on an Apple-silicon Mac:

| level | encode | decode (incl. sheet decode, amortised) |
| --- | ---: | ---: |
| grid 384 HEIC | 1.5 ms | 0.72 ms |
| preview 64 HEIC | 0.39 ms | 0.03 ms |
| current 900 JPEG | 3.2 ms | 1.52 ms |

Encoding one photo's two atlas cells costs ~2 ms on top of the 3.2 ms the app
already spends on its 900 px thumbnail (+62%). It happens once, at upload.

### Time to paint (10 screens = 150 tiles)

Median wall time from the first request until the last tile is decoded and
ready to draw. Requests and bytes are what the bucket actually served.

**Mobile: 80 ms RTT, 8 Mbps per connection**

| strategy | requests | bytes | first tile | all 150 |
| --- | ---: | ---: | ---: | ---: |
| current (900 px individual) | 150 | 26.3 MB | 154 ms | **11.83 s** |
| right-sized (384 px individual) | 150 | 4.06 MB | 94 ms | 2.50 s |
| grid atlas | 5 | 3.05 MB | 597 ms | **0.80 s** |
| preview atlas | 5 | 116 KB | 100 ms | **0.107 s** |

**Wi-Fi, shaped: 25 ms RTT, 60 Mbps per connection**

| strategy | requests | bytes | first tile | all 150 |
| --- | ---: | ---: | ---: | ---: |
| current | 150 | 26.3 MB | 38 ms | **1.89 s** |
| right-sized | 150 | 4.06 MB | 28 ms | 0.91 s |
| grid atlas | 5 | 3.05 MB | 98 ms | **0.23 s** |
| preview atlas | 5 | 116 KB | 34 ms | **0.046 s** |

**Cold first screen (15 tiles), mobile**

| strategy | requests | bytes | first tile | all 15 |
| --- | ---: | ---: | ---: | ---: |
| current | 15 | 2.15 MB | 154 ms | 1.06 s |
| grid atlas | 1 | 534 KB | 645 ms | 645 ms |
| preview atlas | 1 | 21 KB | **105 ms** | 105 ms |

The grid atlas is the fastest way to finish a scroll and the **slowest** way to
paint the first tile on a high-RTT link: one 534 KB sheet on one stream is worse
than fifteen small files on six. That is why the preview level exists and why
the app paints previews synchronously before it ever asks for a grid sheet.

Decode in this harness is serial per arriving sheet (5 × 26 ms = 130 ms of the
grid number). The app decodes up to four sheets concurrently, so the grid figure
is a conservative upper bound.

## End-to-end check in the app

The tables above use the real encoder and S3 client, but they replay the grid
in a CLI. `Tools/AtlasBench/ui-smoke.sh` closes that gap: it seeds two mock
buckets with the same 300-photo remote-only library — one with atlas pointers,
one without — installs the app on a simulator, opens each, and counts what the
bucket served in the 10 seconds after launch.

| bucket | per-photo GETs | grid sheets | preview sheets |
| --- | ---: | ---: | ---: |
| no atlas (today) | 34 | 0 | 0 |
| atlases | **0** | 3 | 9 |

The same first screens cost ~1.8 MB here instead of ~6.1 MB, and the bucket sees
12 requests instead of 34 (and one GET, the index, either way). Both launches
also fetch a handful of 1,200 px viewer previews, which is why the script
compares the two cases instead of asserting a literal zero.

## Keeping it up to date, and correlating with S3

This is the part that decides whether the feature is cheap or a liability.

**Sheets are immutable and content-addressed.** A group id is the SHA-256 of the
ordered member digests truncated to 20 hex characters. A photo stores only
`(group, cell)`; both levels are derived from that pair:

```
.backu/atlas/v1/grid/<group>.heic      6×6 cells, 384 px
.backu/atlas/v1/preview/<group>.heic   6×6 cells, 64 px
.backu/atlas/v1/grid/<group>.json      self-describing sidecar (audit/repair)
```

Consequences:

- **No invalidation.** Editing tags, favourites, people or metadata does not
  touch pixels, so the pointer is unchanged. Replacing a photo's bytes changes
  its SHA-256, which produces a new group. A cached sheet can be kept forever;
  the only eviction is the cache's own LRU.
- **No read-modify-write on sheets.** Every device publishes new groups and
  never rewrites an existing one, so two phones uploading at once cannot
  clobber each other. There is no manifest to lock and no ETag to poll.
- **The pointer travels with the photo.** It is written to `index.json` next to
  the object key and to the photo's sidecar. A second device learns it in the
  same request it already makes to import the library. The app browses from the
  index; the sidecar is a repair path for a bucket with no index.
- **Partial failures degrade, they do not break.** Publish order is sheet →
  sheet sidecar → index. A crash after the sheet PUT leaves an unreferenced
  sheet (harmless). A crash before the pointer leaves a photo on the 900 px
  thumbnail, and the next backup run re-renders the atlas from the local
  original without re-uploading bytes (`photosMissingAtlas`, bounded to 500 per
  run so upgrading a huge existing library does not re-export it all at once).
- **Deletions need a collector, not a rewrite.** A deleted photo's sheet simply
  stops being referenced. Collecting it is a separate `LIST .backu/atlas/` pass
  compared against index references; it is not on any hot path. Until then the
  waste is ~18 KB per deleted photo.

Cost of a new photo, measured:

| | current | with atlases |
| --- | ---: | ---: |
| PUTs per photo | 1 thumbnail + 1 sidecar + 1 original | + 2 sheet PUTs / 36 photos + 2 sidecar PUTs / 36 |
| bytes per photo | 184 KB | +18 KB (+10%) |
| encode CPU | 3.2 ms | +2 ms (+62%) |

The storage increase is the price of keeping the 900 px thumbnail for the
viewer. If the grid atlas ever replaced it, total storage would fall.

**New device sync.** The index is one GET. Pulling every preview for 100k
photos is 2,778 sheets, 67 MB, about 50 s at 6 concurrent requests on the mobile
profile — after which the whole library scrolls with no network and no blank
tiles. 2,778 GETs is roughly $0.001 on S3.

## Design alternatives that lost

- **Mutable monthly contact sheets.** Rewriting a sheet changes its bytes, so
  every client must invalidate, and every upload rewrites a large object.
  Rejected: worse than no cache.
- **One giant atlas plus `Range` requests per tile.** A range GET is still one
  request, so it saves nothing on the metric that matters, and one corrupt cell
  invalidates gigabytes.
- **A per-bucket `sheets.json` manifest.** Concurrent devices lose updates with
  no compare-and-swap on S3. Per-photo pointers in the index the app already
  rewrites avoid the problem entirely.
- **A zip of individual thumbnails per batch.** Same request count as a sheet,
  more code, and no single decode.

## Verdict

**Implement it, but as two tiers and only for remote-only photos.**

- The **preview atlas is an unambiguous win.** 67 MB holds a 100k-photo
  library; a 10-screen fling costs 116 KB and 107 ms on the mobile profile
  instead of 26 MB and 11.8 s. It also makes the library browsable offline,
  which the app could not do before. Nothing else in this design comes close
  per byte spent.
- The **grid atlas is a solid but smaller win.** 8× faster and 30× fewer
  requests than today on Wi-Fi, 15× faster on mobile. Most of the *byte* saving
  would also come from simply requesting a 384 px thumbnail instead of a
  900 px one; the atlas's unique contribution is the request count and the
  cacheable whole-library tier.
- **Do not ship the grid atlas without the preview tier.** On a high-RTT link a
  cold grid sheet is slower to first paint than today's small individual files.

When it is not worth it: a single-device library whose originals are all in
Photos. PhotoKit already caches and prefetches those better than any app-level
scheme. The feature earns its keep on the restore / second-device path that the
README already advertises, which is also where the app can hold no originals at
all.
