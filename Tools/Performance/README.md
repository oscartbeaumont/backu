# Scroll performance harness

A dedicated, disposable simulator with 300 synthetic photos so scrolling can be
measured without touching the shared test devices or the marketing library.

## Prepare

```sh
swift Tools/Performance/make-large-library.swift   # 300 × 900×900 JPEGs, 2012–2026
./Tools/Performance/setup.sh                        # erase "Backu Perf", add media, install app
```

`setup.sh` creates `Backu Perf` (iPhone 17 Pro, iOS 26.5) if needed, resets it,
adds `Tests/Fixtures/performance/library` (git-ignored), builds and installs the
Debug app, and grants Photos. It prints the simulator UDID.

## Run

```sh
TEST_RUNNER_BACKU_PERF=1 xcodebuild -project Backu.xcodeproj -scheme Backu \
  -destination 'platform=iOS Simulator,name=Backu Perf' \
  -only-testing:BackuUITests/ScrollPerformanceTests/testScrollPerformance \
  -resultBundlePath /private/tmp/backu-perf test
```

The test skips unless `BACKU_PERF=1` reaches the test runner, so normal CI runs
and `scripts/test.sh` never run the benchmark.

It records, for the cold grid and after fast flings:

- time from launch to the first tile and to the first 9/27 ready tiles
- peak tiles still loading (a `#if DEBUG` probe keeps a trailing 3 s peak,
  because XCUITest queries wait for quiescence and hide transient placeholders)
- scroll deceleration + clock + peak memory via `XCTMeasure` (three fast swipes)
- screenshots of the cold grid and the settled grid (status-bar scrim, month pill)

Exported attachments live in the `.xcresult`; see `Tools/Screenshots/README.md`
for the export command.

## Baseline vs after (iPhone 17 Pro "Backu Perf", iOS 26.5)

Baseline is commit `8d47e1f` (pass 2) plus only the measurement seams: the tile
accessibility value and the debug probe. Both runs used a freshly erased
simulator with the same 300 photos and `BACKU_RESET=1`.

| Metric | Baseline | After | Change |
| --- | ---: | ---: | ---: |
| First tile from launch | 11.31 s | 11.28 s | launch-bound |
| + to 9 ready tiles | 0.31 s | 0.35 s | noise |
| + to 27 ready tiles | 1.02 s | 1.14 s | noise |
| Blank tiles (cold peak) | 33 of 33 | 33 of 33 | structural* |
| Peak loading during fling | 3 | 3 | 0 |
| Loading after settling | 0 of 24 | 0 of 24 | 0 |
| Scroll deceleration | 2.420 s | 2.426 s | +0.2% |
| Clock (3 swipes + idle) | 8.072 s | 7.931 s | −1.7% |
| Peak memory | 50,160 kB | 38,023 kB | −24% |

\* Every realized tile starts blank on the first frame, so the peak equals the
realized tile count. The probe also tracks degraded-preview paints separately;
on 900×900 local assets PhotoKit's degraded pass lands in the same frame as the
final, so blank and final peaks match. Progressive delivery is still visible for
remote and high-resolution assets.

Memory is the metric with real, repeatable movement: across four after runs the
peak ranged 33.7–48.4 MB, always below the 50.2 MB baseline (median ≈ 41 MB).
The simulator's PhotoKit thumbnail cache accounts for most of the spread.

Notes:

- Scroll-deceleration signposts end when physics ends, so this metric is mostly
  a function of the fling velocity; the clock metric includes XCUITest's idle
  waits and varies 2–6% between runs.
- The synthetic 900×900 originals decode in a few milliseconds, so the baseline
  is already at the floor for placeholder counts and time-to-ready on this
  simulator. Re-run with 12 MP sources (the generator's `side` constant) to
  expose the decode/prefetch difference.
