# Pass 3 analysis and results

## Why pass 2 stopped at six connections for 32 MiB

`TransferPlanner.plan` computed `feedable = floor(size / 5 MiB)`. For a 32 MiB
upload that is 6, so `wantedParts` was clamped to 6 even though S3 allows a
*larger* part count as long as every part except the last is >= 5 MiB:
32 MiB = 6 x 5 MiB + 1 x 2 MiB = 7 parts. Six connections therefore ran
6 x 5.33 MiB parts and never used the seventh lane. (S3 caps a 32 MiB object at
7 useful lanes, so 6.4 "5 MiB units" is the hard ceiling for that size.)

## Why 128 MiB stopped at eight connections

`desiredConcurrency` returned 8 for wired and 8 for large Wi-Fi objects, while
`connectionBudget` and `URLSession.httpMaximumConnectionsPerHost` were already
10. Nothing ever planned 9 or 10. The background uploader's session also capped
`httpMaximumConnectionsPerHost` at 8, so even a 10-connection plan would have
been throttled in the real app.

## Download assembly

`downloadParallel` wrote each completed range to a UUID temp file, then after
*every* range finished it re-read all of them and concatenated into
`destination.part`. That is a full extra read+write of the object on the critical
path (128 MiB ~ 40-60 ms) and doubles the bytes written. It also meant a crash
during assembly could leave a full-length `.part` that the single-stream resume
path would happily promote to the final file.

## Other overhead

* `downloadObject` issued a HEAD for every large download, including repeated
  viewer opens of the same object and every benchmark iteration.
* The direct multipart path created a temp directory on every upload, and
  `concurrency x partSize` could reach 128 MiB (8 x 16 MiB) of live part payload.
  Measured peak *internal* memory with a 128 MiB upload at 10 connections was
  609 MiB in-memory versus 291 MiB with staging, at identical throughput.
* `createMultipartUpload`'s UploadId was never persisted, so a crash left an
  orphaned upload that only a bucket lifecycle rule could clean up.
* A single unlucky range/part could fail a whole transfer: the failure-injecting
  harness made pass 2 fail an entire 32 MiB download, and 5 attempts fail about
  one request in 400 at a 30 % transient rate.

## What pass 3 changes

Planner (`TransferTuning.swift`):

* `feedable` uses `ceil`, and the *work per connection* is 5 MiB for uploads and
  4 MiB for downloads. 32 MiB uploads now plan 7 x 5 MiB-at-most parts, 32 MiB
  downloads plan 8 x 4 MiB ranges, 128 MiB downloads plan 10 ranges.
* Unmetered links (wired/Wi-Fi/unknown) fill the allowance up to an
  **unmeasured ceiling of 8**; a proven-scaling history raises it to the
  10-connection budget. "Proven" means: the last transfer used >= 8 connections,
  its raw throughput was within 85 % of the best aggregate ever seen, and its
  per-connection throughput was within 85 % of the best per-connection figure.
  A regression drops back to 8; failures cost one growth step each.
* Part counts are balanced into whole waves, so 100 MiB at 8 connections is
  8 x 12.5 MiB rather than 13 x 8 MiB with five idle sockets in the last wave.
* Payload budget `min(96 MiB, RAM/16)` covers the parts *and* URLSession's copy
  of each in-memory body; above it the parts are staged to disk instead of
  collapsing the plan.
* Cellular/expensive/constrained keep their 4/3/2 caps regardless of history.

Transfers:

* Parallel downloads write each finished range straight into its slot in a
  preallocated file with `pwrite`, overlapping assembly with the remaining
  network time. The assembled file lives in the per-download directory, so a
  failure or crash cannot leave a fake-complete `.part`.
* HEAD results (size, ETag, Accept-Ranges, observed RTT) are cached per
  server + key for 60 s; writes and deletes through `S3Client` invalidate the
  key, and a 412 (single or parallel) drops it and re-probes once.
* Multipart upload ids are journalled to Application Support before the first
  part and cleared on complete/abort. `BackupEngine` aborts records older than a
  day for its server at the start of a run. Uploads whose create response was
  lost are covered by a documented bucket lifecycle rule
  (`AbortIncompleteMultipartUpload`), not by ListMultipartUploads.
* Parts and ranges retry 7 times instead of 5.
* Background upload sessions use the full 10-connection budget.

## Measured (shaped 60 Mbps/connection, 25 ms RTT, 3 runs + 1 warm-up)

| operation | size | pass 2 | pass 3 | change |
|---|---|---|---|---|
| upload | 32 MiB | 38.15 | 40.03 | +4.9 % |
| upload | 128 MiB | 53.99 | 65.40 | +21.1 % |
| download | 32 MiB | 40.73 | 56.78 | +39.4 % |
| download | 128 MiB | 55.61 | 70.53 | +26.8 % |

The 32 MiB upload is the one scenario that misses the 15 % target. With the
5 MiB minimum, 32 MiB can use at most 6.4 lanes; pass 2 was already at ~97 % of
the per-connection bucket, so the legal ceiling for that object is about +7 %.
It gains +4.9 % (six 5 MiB parts plus the 2 MiB tail). Nothing compliant can do
better on a per-connection-shaped link; the remaining headroom would need
per-connection capacity above the mock's 60 Mbps (HTTP/3, S3 Transfer
Acceleration, or a shared-bottleneck link where bigger parts win).

Download gains come from 8/10 ranges instead of 6/8 and from removing the
sequential concatenation pass. 128 MiB upload gains come from 10 connections at
12.8 MiB parts. The HEAD cache removes one request per repeated download
(visible as 9 -> 10 requests for a 10-range download where the HEAD is now free,
2 -> 1 on localhost).
