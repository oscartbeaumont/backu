# Transfer benchmark

A standalone Swift CLI compiled with `swiftc` (no SPM, no dependencies) against
the app's real S3 sources. It measures:

- **upload**: one `PUT` (baseline) versus an adaptive S3 multipart upload
- **download**: one whole-object `GET` into memory (baseline) versus a streaming
  single connection or adaptive parallel byte ranges
- 4, 32 and 128 MiB objects, one warm-up and three measured runs, median MB/s
- HTTP request count, retry count, and the part size/concurrency the tuning layer
  actually chose for every measured run

## Run it

```sh
./Tools/Benchmark/run.sh
```

That builds `/tmp/backu-bench`, starts three mock buckets (shaped, localhost and
a 30 % failure-injecting one) on ports 9101–9103, and writes:

```
Tools/Benchmark/results/pass3-shaped.json
Tools/Benchmark/results/pass3-localhost.json
Tools/Benchmark/results/pass3-cellular.json
Tools/Benchmark/results/pass3-retry.json
```

`pass1-*` and `pass2-*` results are kept for comparison. Print the comparison
between two passes with:

```sh
python3 Tools/Benchmark/compare.py                 # pass2 -> pass3
python3 Tools/Benchmark/compare.py --from pass1 --to pass2
```

Every measured run also records the peak *internal* memory (anonymous pages,
excluding reclaimable file mappings) from a 25 ms sampler, so the payload budget
in `TransferPlanner` can be checked rather than assumed. It is a process
high-water mark, so it only ever grows over a run; `--sizes 128 --mode new` in a
fresh process measures one scenario cleanly.

The run ends with `Tools/Benchmark/audit_log.py`, which reads the shaped mock's
request log and prints the parts the server actually received for each multipart
upload, the GET count per key, and any upload that was created with parts but
neither completed nor aborted.

Useful overrides:

```sh
BACKU_BENCH_SIZES=4,32 BACKU_BENCH_RUNS=3 ./Tools/Benchmark/run.sh
BACKU_BENCH_PORT_BASE=9200 ./Tools/Benchmark/run.sh
```

You can also drive it by hand against an already-running mock:

```sh
swiftc -O -o /tmp/backu-bench \
  Sources/Core/Models/StorageProvider.swift \
  Sources/Core/Models/ServerConfig.swift \
  Sources/Core/S3/*.swift Tools/Benchmark/main.swift

/tmp/backu-bench --endpoint http://127.0.0.1:9101 --profile shaped --mode both
```

Adaptive tuning is the default. `--network wifi|wired|cellular|expensive|constrained`
sets the link type the planner sees, and `--concurrency N` / `--part-size-mb N`
force the old fixed behaviour for an A/B. The history is in-memory per process,
so the warm-up is what seeds the EWMA, exactly like the first transfer after a
fresh install. The app persists the same EWMA per endpoint + bucket in
`UserDefaults`, so later launches start tuned.

## What the shaping models

`--bandwidth-mbps 60` is a **per-connection token bucket** in the mock. It is
applied to request body reads and response writes, with `--latency-ms 25` and
seeded jitter added per request. Four connections therefore see up to four
times the single-connection rate; eight see up to eight.

That models one common case: a mobile or high-RTT link where one TCP stream
cannot fill the pipe, so parallel parts/ranges help. It does **not** model a
shared bottleneck, bufferbloat, packet loss, radio scheduling, or every real
network. A link that is already single-stream fast (localhost, a good LAN) keeps
the single-stream path, which is why the downloader probes round-trip latency
even when the caller already knows the size.

Numbers are only comparable when the mock flags, object size, run count and
warm-up count match. The JSON report records all of them. Localhost transfers
finish in tens of milliseconds, so their medians are dominated by page-cache and
scheduler noise; use the controlled A/B in the pass 2 report rather than a
single harness run for those.

## Pass 2 results (shaped: 60 Mbps/connection, 25 ms RTT)

Median MB/s, one warm-up + three measured runs:

| operation | size | pass 1 | pass 2 | change | pass 2 plan |
|---|---|---|---|---|---|
| upload | 4 MiB | 7.05 | 7.04 | -0.2% | single PUT |
| upload | 32 MiB | 26.14 | 37.95 | +45.1% | 5.33 MiB × 6 |
| upload | 128 MiB | 27.47 | 53.84 | +96.0% | 16 MiB × 8 |
| download | 4 MiB | 7.14 | 7.16 | +0.3% | single stream |
| download | 32 MiB | 27.60 | 40.58 | +47.0% | 5.33 MiB × 6 |
| download | 128 MiB | 28.21 | 55.69 | +97.4% | 16 MiB × 8 |

Failure injection (30 % of requests return 503, same shaped link, 32 MiB):
upload 11.74 → 17.01 MB/s (+44.9%), download 18.13 → 32.11 MB/s (+77.1%).
Cellular (same shaped mock, planner capped at four connections): 32 MiB
26.20/27.54 MB/s up/down, 128 MiB 27.53/28.19 MB/s, i.e. pass 1's throughput with
a deliberate connection cap rather than a regression.

## Pass 3 results (shaped: 60 Mbps/connection, 25 ms RTT)

Median MB/s, one warm-up + three measured runs (`results/pass3-shaped.json`):

| operation | size | pass 2 | pass 3 | change | pass 3 plan |
|---|---|---|---|---|---|
| upload | 4 MiB | 7.03 | 7.01 | -0.4% | single PUT |
| upload | 32 MiB | 38.15 | 40.03 | +4.9% | 5 MiB × 7 (6 × 5 MiB + 2 MiB tail) |
| upload | 128 MiB | 53.99 | 65.40 | +21.1% | 12.8 MiB × 10, staged parts |
| download | 4 MiB | 7.14 | 7.14 | 0.0% | single stream |
| download | 32 MiB | 40.73 | 56.78 | +39.4% | 4 MiB × 8 |
| download | 128 MiB | 55.61 | 70.53 | +26.8% | 12.8 MiB × 10 |

Repeated runs of the same tree land within about ±2% of these medians
(32 MiB upload 39.8-40.3, 128 MiB upload 65.4-66.6, 32 MiB download 56.4-57.0,
128 MiB download 70.2-70.5).

The 32 MiB upload cannot reach ten lanes: S3 requires every part except the last
to be at least 5 MiB, so 32 MiB tops out at 6 × 5 MiB + 2 MiB. Pass 2 was already
at ~97 % of the per-connection token bucket for those parts, so 7 lanes buy one
more 5 MiB lane of capacity (the 2 MiB tail frees its socket early), not another
4 lanes. Downloads have no such floor, which is why the same object gains 39 %.

The retry profile (30 % of requests return 503) is deterministic per *request
order*, so comparing two passes through `run.sh` is not fair: pass 3 issues a
different number of parts and ranges, which shifts which requests the seeded
mock fails. A controlled A/B on five fresh mocks per pass (same seed, 32 MiB,
`--mode new`) gives upload 19.00 → 18.46 MB/s (-3 %, parity) and download
17.24 → 40.79 MB/s (+2.4x): the smaller 4 MiB ranges retry in less time than
pass 2's 5.33 MiB ranges, and parts/ranges now get seven attempts instead of
five, so one unlucky request no longer fails the object.

Localhost is a no-regression guard, not a throughput target: a 128 MiB transfer
finishes in 20-100 ms, so a single three-run median can swing by tens of percent
(the harness run above shows 128 MiB upload at 1149 MB/s while a seven-run A/B
measured 1565 MB/s for the same plan). A controlled A/B against the pass 2
binary on an unshaped mock, seven measured runs x three rounds, gives:

| operation | size | pass 2 | pass 3 | change |
|---|---|---|---|---|
| upload | 32 MiB | 1117 | 1234 | +10.5% |
| upload | 128 MiB | 1603 | 1566 | -2.3% |
| download | 32 MiB | 2908 | 4230 | +45.4% |
| download | 128 MiB | 3128 | 5396 | +72.5% |

The download difference is mostly the removed HEAD round trip (2 -> 1 request)
and, for small objects, the same page-cache variance; the upload plans are
identical to pass 2 on a low-RTT link.
