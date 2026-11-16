# Transfer benchmark

A standalone Swift CLI compiled with `swiftc` (no SPM, no dependencies) against
the app's real S3 sources. It measures:

- **upload**: one `PUT` (baseline) versus S3 multipart with 4 parts in flight
- **download**: one whole-object `GET` into memory (baseline) versus a streaming
  single connection or parallel byte ranges, depending on the link
- 4, 32 and 128 MiB objects, one warm-up and three measured runs, median MB/s
- HTTP request count and retry count for every measured run

## Run it

```sh
./Tools/Benchmark/run.sh
```

That builds `/tmp/backu-bench`, starts three mock buckets (shaped, localhost and
a 30 % failure-injecting one) on ports 9101–9103, and writes:

```
Tools/Benchmark/results/pass1-shaped.json
Tools/Benchmark/results/pass1-localhost.json
Tools/Benchmark/results/pass1-retry.json
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

## What the shaping models

`--bandwidth-mbps 60` is a **per-connection token bucket** in the mock. It is
applied to request body reads and response writes, with `--latency-ms 25` and
seeded jitter added per request. Four connections therefore see up to four
times the single-connection rate.

That models one common case: a mobile or high-RTT link where one TCP stream
cannot fill the pipe, so parallel parts/ranges help. It does **not** model a
shared bottleneck, bufferbloat, packet loss, radio scheduling, or every real
network. A link that is already single-stream fast (localhost, a good LAN) will
not show a parallel gain, which is why the downloader probes round-trip latency
and stays on one stream when the link is local.

Numbers are only comparable when the mock flags, object size, run count and
warm-up count match. The JSON report records all of them.
