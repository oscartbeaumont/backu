#!/usr/bin/env bash
# Builds the metadata log benchmark against a plain mock bucket.
#
#   ./Tools/MetaBench/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

BENCH="${BACKU_META_BENCH_BIN:-/tmp/backu-meta-bench}"
RESULT_DIR="${BACKU_META_BENCH_RESULTS:-Tools/MetaBench/results}"
PHOTOS="${BACKU_META_BENCH_PHOTOS:-100000}"
EDITS="${BACKU_META_BENCH_EDITS:-100}"
PORT="${BACKU_META_BENCH_PORT:-9500}"
PASS="${BACKU_META_BENCH_PASS:-pass1}"

mkdir -p "$RESULT_DIR"

echo "→ Building $BENCH"
swiftc -O -o "$BENCH" \
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
  Tools/MetaBench/main.swift

WORK="${TMPDIR:-/tmp}/backu-meta-bench-s3"
rm -rf "$WORK" && mkdir -p "$WORK"
python3 Tools/MockS3/mock_s3.py --port "$PORT" --data-dir "$WORK" --quiet \
  >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
sleep 1

echo "→ Measuring $PHOTOS photos, $EDITS edits"
"$BENCH" \
  --photos "$PHOTOS" \
  --edits "$EDITS" \
  --endpoint "http://127.0.0.1:$PORT" \
  --output "$RESULT_DIR/$PASS.json"

echo "Report written to $RESULT_DIR/$PASS.json"
