#!/usr/bin/env bash
# Builds and runs the sync-path benchmark (cold start, warm sync, seed) for a
# 100k-photo library. Every scenario runs in its own process so peak RSS is
# attributable, and `prepare` writes the fixture first for the same reason.
#
#   ./Tools/MetaBench/sync.sh
#   BACKU_SYNC_BENCH_PHOTOS=20000 BACKU_SYNC_BENCH_RUNS=3 ./Tools/MetaBench/sync.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

BENCH="${BACKU_SYNC_BENCH_BIN:-/tmp/backu-sync-bench}"
DIR="${BACKU_SYNC_BENCH_DIR:-${TMPDIR:-/tmp}/backu-sync-bench}"
PHOTOS="${BACKU_SYNC_BENCH_PHOTOS:-100000}"
RUNS="${BACKU_SYNC_BENCH_RUNS:-3}"
LATENCY="${BACKU_SYNC_BENCH_PUT_LATENCY_MS:-15}"
OUT="${BACKU_SYNC_BENCH_OUT:-Tools/MetaBench/results/sync-$(date +%Y%m%d-%H%M%S).jsonl}"
SERVER_ID="00000000-0000-0000-0000-00000000BEEF"

mkdir -p "$(dirname "$OUT")"

echo "→ Building $BENCH"
EXTRA_FLAGS=()  # bash 3.2 treats an empty array expansion as unset under `set -u`
# The streaming-download hook only exists after the optimisation pass; the same
# script also has to build the old tree for a before/after comparison.
if ! grep -q "MetadataDownloadResult" Sources/Core/Metadata/MetadataStore.swift; then
  EXTRA_FLAGS+=(-D BACKU_BENCH_LEGACY_STORE)
fi

swiftc -O ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} -o "$BENCH" \
  Sources/Core/Models/StorageProvider.swift \
  Sources/Core/Models/ServerConfig.swift \
  Sources/Core/Models/PhotoItem.swift \
  Sources/Core/Models/Person.swift \
  Sources/Core/S3/*.swift \
  Sources/Core/Storage/AppPaths.swift \
  Sources/Core/Sync/Sidecar.swift \
  Sources/Core/Metadata/Gzip.swift \
  Sources/Core/Metadata/MetadataModels.swift \
  Sources/Core/Metadata/MergedMetadata.swift \
  Sources/Core/Metadata/MetadataStore.swift \
  Sources/Core/Metadata/MetadataService.swift \
  Sources/Core/Catalog/SearchIndex.swift \
  Sources/Core/Catalog/CatalogStore.swift \
  Tools/MetaBench/SyncBench/main.swift

: >"$OUT"

echo "→ Preparing a $PHOTOS-photo fixture in $DIR"
"$BENCH" --scenario prepare --photos "$PHOTOS" --dir "$DIR"

state_dir="$HOME/Library/Application Support/Backu/metadata"
clear_state() {
  rm -f "$state_dir/$SERVER_ID-state.json" \
        "$state_dir/$SERVER_ID-cache.jsonl.gz" \
        "$state_dir/$SERVER_ID-outbox.jsonl"
}

run() {
  local scenario="$1"
  shift
  "$BENCH" --scenario "$scenario" --photos "$PHOTOS" --dir "$DIR" \
    --server-id "$SERVER_ID" "$@" | tee -a "$OUT"
}

echo "→ Cold start ($RUNS runs)"
for _ in $(seq 1 "$RUNS"); do run cold; done

echo "→ Warm sync with one changed photo ($RUNS runs)"
for _ in $(seq 1 "$RUNS"); do
  clear_state
  "$BENCH" --scenario prime --photos "$PHOTOS" --dir "$DIR" --server-id "$SERVER_ID" >/dev/null
  run warm
done

echo "→ Seed of $PHOTOS photos ($RUNS runs, ${LATENCY} ms simulated PUT)"
for _ in $(seq 1 "$RUNS"); do
  clear_state
  run seed --put-latency-ms "$LATENCY"
done

echo ""
echo "Raw results: $OUT"
python3 - "$OUT" <<'PY'
import json, statistics, sys

rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip().startswith("{")]
by = {}
for row in rows:
    by.setdefault(row["scenario"], []).append(row)

print(f"{'scenario':10} {'photos':>8} {'median s':>10} {'peak RSS MB':>12}")
for name, group in by.items():
    seconds = statistics.median(r["seconds"] for r in group)
    rss = statistics.median(r["peakRSSMB"] for r in group)
    print(f"{name:10} {group[0]['photos']:>8} {seconds:>10.3f} {rss:>12.1f}")
PY
