#!/usr/bin/env bash
# Builds the standalone transfer benchmark and runs the baseline-vs-new matrix
# against the shaped, localhost and failure-injecting mock buckets.
#
#   ./Tools/Benchmark/run.sh
#
# Override with BACKU_BENCH_SIZES=4,32 (MiB), BACKU_BENCH_RUNS=3, BACKU_BENCH_PORT_BASE=9200.
set -euo pipefail
cd "$(dirname "$0")/../.."

BENCH_BIN="${BACKU_BENCH_BIN:-/tmp/backu-bench}"
RESULT_DIR="${BACKU_BENCH_RESULTS:-Tools/Benchmark/results}"
SIZES="${BACKU_BENCH_SIZES:-4,32,128}"
RUNS="${BACKU_BENCH_RUNS:-3}"
BASE_PORT="${BACKU_BENCH_PORT_BASE:-9101}"
WORK="${BACKU_BENCH_WORK:-${TMPDIR:-/tmp}/backu-bench-s3}"
MOCK="Tools/MockS3/mock_s3.py"

mkdir -p "$RESULT_DIR" "$WORK"

echo "→ Building $BENCH_BIN"
swiftc -O -o "$BENCH_BIN" \
  Sources/Core/Models/StorageProvider.swift \
  Sources/Core/Models/ServerConfig.swift \
  Sources/Core/S3/*.swift \
  Tools/Benchmark/main.swift

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

start_mock() {
  local port="$1"
  shift
  rm -rf "$WORK/$port"
  mkdir -p "$WORK/$port"
  python3 "$MOCK" --port "$port" --data-dir "$WORK/$port" --quiet "$@" \
    >"$WORK/mock-$port.log" 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
      return 0
    fi
    sleep 0.1
  done
  echo "mock on port $port did not start; see $WORK/mock-$port.log" >&2
  return 1
}

SHAPED_PORT="$BASE_PORT"
PLAIN_PORT=$((BASE_PORT + 1))
RETRY_PORT=$((BASE_PORT + 2))

start_mock "$SHAPED_PORT" --latency-ms 25 --jitter-ms 5 --bandwidth-mbps 60 --seed 42
start_mock "$PLAIN_PORT"
start_mock "$RETRY_PORT" --latency-ms 25 --jitter-ms 5 --bandwidth-mbps 60 \
  --fail-rate 0.30 --fail-status 503 --seed 7

run_profile() {
  local profile="$1" port="$2" sizes="$3" output="$4"
  echo
  echo "→ $profile (port $port, sizes $sizes MiB)"
  "$BENCH_BIN" \
    --endpoint "http://127.0.0.1:$port" \
    --profile "$profile" \
    --mode both \
    --sizes "$sizes" \
    --runs "$RUNS" \
    --output "$RESULT_DIR/$output"
}

# Shaped: per-connection 60 Mbps + 25 ms latency. This models a single-stream
# limited high-RTT mobile link; parallel connections can add up to ~4x here.
run_profile shaped "$SHAPED_PORT" "$SIZES" "pass1-shaped.json"

# Localhost: no shaping, so this is a correctness and no-regression guard.
run_profile localhost "$PLAIN_PORT" "$SIZES" "pass1-localhost.json"

# Failure injection: proves retries work and that their counts are visible.
run_profile retry "$RETRY_PORT" "32" "pass1-retry.json"

echo
echo "Reports written to $RESULT_DIR:"
ls -1 "$RESULT_DIR"/pass1-*.json
