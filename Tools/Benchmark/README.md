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
Tools/Benchmark/results/pass2-shaped.json
Tools/Benchmark/results/pass2-localhost.json
Tools/Benchmark/results/pass2-cellular.json
Tools/Benchmark/results/pass2-retry.json
```

`pass1-*` results are kept for comparison. Print the comparison with:

```sh
python3 Tools/Benchmark/compare.py
```

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
