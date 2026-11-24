#!/usr/bin/env bash
# Builds the atlas benchmark and runs it against shaped mock buckets.
#
#   ./Tools/AtlasBench/run.sh
#
# Override with BACKU_ATLAS_PHOTOS=300, BACKU_ATLAS_RUNS=3,
# BACKU_ATLAS_PORT_BASE=9301 and BACKU_ATLAS_PASS=pass1 (results prefix).
set -euo pipefail
cd "$(dirname "$0")/../.."

BENCH_BIN="${BACKU_ATLAS_BIN:-/tmp/backu-atlas-bench}"
RESULT_DIR="${BACKU_ATLAS_RESULTS:-Tools/AtlasBench/results}"
PHOTOS="${BACKU_ATLAS_PHOTOS:-300}"
RUNS="${BACKU_ATLAS_RUNS:-3}"
BASE_PORT="${BACKU_ATLAS_PORT_BASE:-9301}"
WORK="${BACKU_ATLAS_WORK:-${TMPDIR:-/tmp}/backu-atlas-s3}"
PASS="${BACKU_ATLAS_PASS:-pass1}"
CORPUS="${BACKU_ATLAS_CORPUS:-Tests/Fixtures/atlas-corpus}"
MOCK="Tools/MockS3/mock_s3.py"

mkdir -p "$RESULT_DIR" "$WORK"

echo "→ Building $BENCH_BIN"
swiftc -O -o "$BENCH_BIN" \
  Sources/Core/Models/StorageProvider.swift \
  Sources/Core/Models/ServerConfig.swift \
  Sources/Core/Models/PhotoItem.swift \
  Sources/Core/Models/Person.swift \
  Sources/Core/S3/*.swift \
  Sources/Core/Storage/AppPaths.swift \
  Sources/Core/Sync/Sidecar.swift \
  Sources/Core/Library/ThumbnailAtlas.swift \
  Tools/AtlasBench/main.swift

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
  rm -rf "${WORK:?}/$port"
  mkdir -p "$WORK/$port"
  python3 "$MOCK" --port "$port" --data-dir "$WORK/$port" "$@" \
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
LOCALHOST_PORT=$((BASE_PORT + 1))
MOBILE_PORT=$((BASE_PORT + 2))

# 25 ms RTT and 60 Mbps per connection: the same shape the transfer benchmark
# uses, so the two reports are comparable.
start_mock "$SHAPED_PORT" --latency-ms 25 --jitter-ms 5 --bandwidth-mbps 60 --seed 42
start_mock "$LOCALHOST_PORT"
# 80 ms RTT and 8 Mbps per connection: a plausible LTE link where requests are
# latency-bound rather than bandwidth-bound.
start_mock "$MOBILE_PORT" --latency-ms 80 --jitter-ms 20 --bandwidth-mbps 8 --seed 11

run_profile() {
  local profile="$1" port="$2"
  echo
  echo "→ $profile (port $port)"
  "$BENCH_BIN" \
    --endpoint "http://127.0.0.1:$port" \
    --profile "$profile" \
    --mode network \
    --photos "$PHOTOS" \
    --runs "$RUNS" \
    --prefix "atlas-bench-$PASS-$profile" \
    --corpus "$CORPUS" \
    --output "$RESULT_DIR/$PASS-$profile.json"
}

echo
echo "→ local encode/decode (no network)"
"$BENCH_BIN" --mode local --photos "$PHOTOS" --corpus "$CORPUS" \
  --output "$RESULT_DIR/$PASS-encode.json"

run_profile shaped "$SHAPED_PORT"
run_profile localhost "$LOCALHOST_PORT"
run_profile mobile "$MOBILE_PORT"

echo
echo "Reports written to $RESULT_DIR:"
ls -1 "$RESULT_DIR"/"$PASS"-*.json

echo
echo "→ Mock request audit (shaped port $SHAPED_PORT)"
python3 - "$WORK/mock-$SHAPED_PORT.log" <<'PY'
import re, sys, collections
counts = collections.Counter()
sizes = collections.Counter()
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"(GET|PUT) (\S+) -> (\d+) (\d+)B", line)
    if not m:
        continue
    method, key, status, size = m.group(1), m.group(2), m.group(3), int(m.group(4))
    if status != "200":
        continue
    kind = "atlas" if "/atlas/" in key else ("current-900" if "current-900" in key else "individual-384")
    counts[(method, kind)] += 1
    sizes[(method, kind)] += size
for (method, kind), count in sorted(counts.items()):
    print(f"  {method:4} {kind:16} {count:5} requests  {sizes[(method, kind)]/1024:10.0f} KB")
PY
