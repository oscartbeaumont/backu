# Metadata log benchmark

A standalone Swift CLI compiled against the app's real metadata format, S3
client and gzip. It compares the old single-document `.backu/index.json` with
the v2 segmented log for a large library.

```sh
./Tools/MetaBench/run.sh
# Results in Tools/MetaBench/results/pass1.json
```

Overrides: `BACKU_META_BENCH_PHOTOS=100000`, `BACKU_META_BENCH_EDITS=100`,
`BACKU_META_BENCH_PORT=9500`.

## What changed

**v1** rebuilt the whole index document and uploaded it on nearly every backup
run and every 20 photos. **v2** appends immutable segment objects to the
writer's own namespace and never rewrites anything:

```
.backu/meta/v2/log/<writer>/<seq>-<hlc>-<hash>.jsonl.gz
.backu/meta/v2/snap/<generation>-<hlc>-<hash>.jsonl.gz
.backu/meta/v2/head.json          # the only mutable object
```

A sync is `GET head` (304 when nothing changed) → `GET snapshot` on cold start
→ `LIST` per writer from the watermark → `GET` only new segments. Compaction is
the only writer of `head.json`; a lost race leaves an orphan snapshot and is
harmless because segments are never deleted.

## Result (100,000 photos, 100 edits)

| | v1 index.json | v2 log |
| --- | ---: | ---: |
| document size | 54.6 MB compact / 80.1 MB pretty | snapshot 13.2 MB gzip |
| one editing session | **54.6 MB, 1 PUT** | **7.3 KB, 1 PUT** (74 B/edit) |
| new device, warm cache | 54.6 MB | 0.2 KB (304) + 7.3 KB |
| new device, cold | 54.6 MB | 0.2 KB + 13.2 MB |
| head | n/a | 0.2 KB |
| one-time migration | n/a | 7.2 MB in 200 segments |

On the mock's localhost profile, the 100-edit session is 7.3 KB / 1.3 ms versus
54.6 MB / 140 ms. On the 8 Mbps mobile profile used by the transfer benchmark,
the same session is about 7 ms of transfer instead of ~55 seconds, and a warm
sync is one 304 round trip plus a 7 KB GET.

Encoding a 100k snapshot costs 690 ms and 13.2 MB compressed; encoding the v1
index costs 692 ms and 54.6 MB. The snapshot is only written by compaction,
every ~8 segments (up to 4,000 edits), not on every sync.

## Why it is conflict-free

- Normal edits only append to `log/<this device>/`, so two devices never write
  the same object. There is no shared file to lock or retry.
- Each record is a field-level patch carrying an HLC; the merge keeps a version
  per field (plus per tag and per face), so concurrent edits to different
  fields both survive. Tag adds use add/remove ops, so two devices adding
  different tags keep both.
- Compaction writes an immutable, content-addressed snapshot and then updates
  `head.json`. Concurrent compactions produce two valid snapshots; the head
  picks one, and because no segments are deleted, a head that points at the
  older snapshot still converges (it just replays more segments).

## Reproduce the earlier failure modes

The mock bucket implements `delimiter` and `start-after`, so local runs
exercise the cheap delimiter path used by S3-compatible services. The
in-memory protocol suite separately covers the fallback when a store lacks
delimiter support.

## Optimisation pass

The log's bytes were already small; the *work around them* was not. A one-photo
sync still materialised all 100k photos, rewrote the 13 MB local cache, and the
catalog walked its whole photo array. This pass removes that per-sync cost.

Measured on this machine — Apple M5 Max, 128 GB, macOS 27.2.1, Xcode 27.2,
Swift 6.4.2, `-O` — with `Tools/MetaBench/sync.sh` (3 runs per scenario, median),
100,000 photos:

| scenario | before | after |
| --- | ---: | ---: |
| cold start (snapshot → merged state) | 3.32 s, 597 MB peak | **3.11 s, 468 MB peak** |
| warm sync, 1 changed photo | 144 ms, 679 MB peak | **1.3 ms, 418 MB peak** |
| returns from a warm sync | 100,000 photos | **1 photo** |
| cache written by that sync | 12.8 MB | **0 B** |
| seed 100k (200 × 500-record PUTs, 15 ms simulated RTT) | 8.54 s, 989 MB | **4.46 s, 1009 MB** |

`peak` is `ru_maxrss` for a process that runs exactly one scenario, so it is the
peak of that scenario rather than of a long-lived app. The warm number is a
relaunch: one process primes the cache (the old code writes it on a background
queue; the script gives it time), then a fresh process syncs one new segment.
The seed's peak is dominated by the 100k-photo `CatalogStore` itself and is
unchanged within noise (≈2%); the win there is wall time.

Run it with:

```sh
./Tools/MetaBench/sync.sh
# Raw JSON lines in Tools/MetaBench/results/sync-<timestamp>.jsonl
```

`BACKU_SYNC_BENCH_PHOTOS=20000` and `BACKU_SYNC_BENCH_RUNS=1` make a quick pass;
`BACKU_SYNC_BENCH_BIN`/`BACKU_SYNC_BENCH_DIR` let you build two checkouts of the
same script against one fixture to compare revisions.

### What changed

1. **Incremental materialisation.** `MergedMetadata.apply(_:)` now returns the
   ids it actually changed or removed, and `materialize(serverID:changes:)` builds
   catalog items for only those. A sync reports `isFull` when it loaded a
   snapshot (or started from empty), so a cold start still materialises
   everything once and a reader knows when it may reconcile absent photos.
   `CatalogStore` keeps id and SHA-256 indexes, so applying one merged photo is
   O(1) instead of two dictionary builds plus an array scan. Deletions use a new
   `removeRemotePhotos(serverID:removedIDs:deletedHashes:)`; `reconcileRemote`
   (which walks the library) is only reached by a full sync.
2. **Throttled cache writes.** The merged-state cache is written when a snapshot
   is loaded, when 2,000 records have accumulated since the last write, or on
   `flushCacheIfNeeded()` (background/termination, wired to
   `flushMetadataNow`). A stale cache stays correct: its header watermark is
   authoritative, so a relaunch replays the few segments it missed.
3. **Streamed snapshot decode.** `MetadataObjectStore` gained
   `downloadObject(_:to:)` (default: buffer; S3: one streaming
   `URLSession.download`), and `MergedMetadata.decodeSnapshot(gzipFile:)`
   inflates with `compression_stream` in 64 KB slices, splitting lines with
   `memchr` and dropping each line after it becomes a merged entity. The 13 MB
   compressed body never coexists with 60 MB of JSON text.
4. **Parallel seed, smarter compaction.** `flush` keeps up to four PUTs in
   flight and only drops the contiguous uploaded prefix, so a retry reuses the
   exact key after a gap-free run; seed queues four 500-record batches before
   flushing. Compaction now triggers on `segmentsSinceSnapshot >= 32` **or**
   `editsSinceSnapshot >= 20,000` (`MetadataCompactionPolicy`, injectable), so
   eight trivial edits no longer re-upload a 13 MB snapshot. Own segments are
   counted once, at write time, not again when the sync reads them back.
5. **Fewer requests.** The sequence probe that used to cost an extra LIST after
   a state-file loss now reads the highest sequence out of the listing the sync
   already performs. A warm sync with nothing new is one conditional head GET
   and two LISTs (delimiter plus per-writer) and no segment GETs; each new
   segment costs exactly one GET. `MetadataIncrementalTests` asserts those
   counts.

### Tradeoffs

- A warm sync now returns only the changed photos, so any consumer that assumed
  `outcome.photos` was the whole bucket must honour `isFull` (in-tree that is
  only `AppModel.applyMerged`).
- The cache can be up to 2,000 records / five minutes behind the state file.
  That trades a small replay on the next launch for not gzipping 13 MB per edit.
- A failed PUT that follows a successful one in the same batch leaves the later
  chunk in the outbox, so its retry gets a fresh sequence number. Records are
  idempotent, so this duplicates bytes, never state; with no gap the retry
  reuses the identical key.
- A person edit still counts faces across every photo, because `faceCount` is
  derived; it is the one O(library) step left on an incremental sync and only
  runs when a person changed.
- The snapshot download used by the in-memory test store still buffers the whole
  object; only S3 streams. The protocol keeps that as a default so a store can
  stay simple.

## Protocol tests (in-memory, no S3)

`Tests/BackuTests/MetadataProtocolTests.swift` drives the journal through
`MetadataObjectStore`, whose production implementation is `S3MetadataStore` and
whose test implementation is `InMemoryMetadataStore` with injectable PUT, GET
and LIST failures, lost responses and object deletion. The cases are chosen
around the ways a journal loses data:

| case | what it proves |
| --- | --- |
| 304 on head with new segments | a steady-state sync still lists and applies edits since the last compaction |
| cold start with a snapshot | head + snapshot + no segment GETs; a reader never writes |
| PUT fails | outbox and sequence stay intact, retry reuses the same key |
| PUT lands, response lost | retry overwrites the same key; no duplicate records |
| flush while another flush runs | the busy caller is told to retry, and the records still drain once |
| segment GET fails | sync throws before advancing the watermark |
| corrupt segment / missing snapshot | retry succeeds after repair; no partial application |
| list failure | the journal is left untouched |
| corrupt head | never triggers migration, seeding, or a head overwrite |
| stale compaction | an old watermark cannot move the head backwards or lose newer edits |
| seed fails mid-batch | relaunch resumes by photo id with no duplicated records |
| state file deleted | sequence probing prevents a writer reusing sequence 0 and becoming invisible |
| nil-SHA copy | a valid record is an upsert, never a delete |
| remote tag + local rescan | the next local diff does not revert the remote edit |
| received future HLC | the local clock overtakes it, so a slow clock can still win later |
| missing delimiter support | falls back to listing the log inline and still converges |
| person delete | survives snapshot compaction and reaches a fresh reader as a deletion |

The same test file is the fastest place to reproduce a journal bug: no mock
server, no network, no simulator.

## Production pass

- **Garbage collection.** After a compaction, a device (at most once a day)
  deletes segments covered by the head snapshot's watermark and older than a
  7-day retention window, plus superseded snapshots. Readers always start from
  the head snapshot, so covered segments are redundant; the window protects a
  sync that listed a segment just before collection.
- **Parallel cold start.** The snapshot now downloads through the regular
  ranged downloader, so a 13 MB snapshot is fetched over parallel byte ranges
  above 8 MB instead of one stream. It still streams to disk.
- **Incremental face counts.** The merged state maintains person→face counts
  on apply, so a face move updates the People screen without scanning the
  library. Counts are rebuilt once when a snapshot is decoded.
- **One-trigger release.** The Release workflow uploads to TestFlight, creates
  the tag and GitHub Release, then adds the build to the `TESTFLIGHT_GROUP`
  repository variable (default `Internal`) through the App Store Connect API.
  Internal groups skip Beta App Review; only external groups wait on Apple.

