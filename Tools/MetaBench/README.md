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

The mock bucket does not implement `delimiter` or `start-after`, which is a
useful robustness test: the reader falls back to listing the log directly and
still converges. A bearer of a real S3-compatible service gets the cheap
delimiter path.
