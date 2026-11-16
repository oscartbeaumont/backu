#!/usr/bin/env bash
# Runs the unit suite (including S3 integration against the mock bucket) and the
# end-to-end UI suite. Screenshots are written inside the xcresult bundles.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${BACKU_SIM:-iPhone 17 Pro}"
DATA_DIR="${BACKU_BUCKET_DIR:-/private/tmp/backu-s3}"
RESULT_DIR="${BACKU_RESULTS:-/private/tmp/backu-results}"

command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

./Tools/Fixtures/download-fixtures.sh
swift Tools/Fixtures/prepare-fixtures.swift >/dev/null

pkill -f "mock_s3.py.*--data-dir $DATA_DIR" 2>/dev/null || true
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR" "$RESULT_DIR"
python3 Tools/MockS3/mock_s3.py --data-dir "$DATA_DIR" --quiet >/tmp/backu-mock-s3.log 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
sleep 1

echo "→ Unit tests"
xcodebuild -project Backu.xcodeproj -scheme Backu \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -only-testing:BackuTests \
  -resultBundlePath "$RESULT_DIR/unit.xcresult" test

echo "→ Mock S3 tool tests"
python3 Tools/MockS3/test_mock_s3.py

echo "→ UI tests (backup, naming, search, servers)"
rm -rf "$DATA_DIR"/* 
xcodebuild -project Backu.xcodeproj -scheme Backu \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -only-testing:BackuUITests \
  -resultBundlePath "$RESULT_DIR/ui.xcresult" test

echo
echo "Everything passed. Results: $RESULT_DIR"
echo "Uploaded objects: $(find "$DATA_DIR" -name '*.bin' | wc -l | tr -d ' ')"
