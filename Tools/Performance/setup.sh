#!/usr/bin/env bash
# Prepares the dedicated scroll-performance simulator.
#
#   ./Tools/Performance/setup.sh
#
# The device is deliberately separate from the shared iPhone 17 Pro so the
# 300-photo library never leaks into feature UI tests. The script resets that
# simulator (so repeated runs never duplicate photos), adds the synthetic
# library, installs the app and grants Photos. It does not launch the app.
set -euo pipefail
cd "$(dirname "$0")/../.."

DEVICE_NAME="${BACKU_PERF_DEVICE:-Backu Perf}"
DEVICE_TYPE="${BACKU_PERF_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
RUNTIME="${BACKU_PERF_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
BUNDLE_ID="me.otbeaumont.backu"
FIXTURE_DIR="Tests/Fixtures/performance/library"
DERIVED="${BACKU_PERF_DERIVED:-/private/tmp/backu-perf-derived}"

if [[ ! -f "$FIXTURE_DIR/IMG_1000.JPG" ]]; then
  swift Tools/Performance/make-large-library.swift
fi

command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen"; exit 1; }

UDID="$(xcrun simctl list devices available | sed -n "s/^    ${DEVICE_NAME} (\([0-9A-F-]*\)) (.*/\1/p" | head -1)"

if [[ -z "${UDID:-}" ]]; then
  echo "→ creating simulator: $DEVICE_NAME"
  UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")"
else
  echo "→ reusing simulator: $DEVICE_NAME ($UDID)"
fi

echo "→ resetting the performance simulator"
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$UDID"

echo "→ generating the app"
xcodegen generate >/dev/null
xcodebuild -project Backu.xcodeproj -scheme Backu \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build >/tmp/backu-perf-build.log || {
    tail -40 /tmp/backu-perf-build.log; exit 1
  }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Backu.app"
xcrun simctl install "$UDID" "$APP"

echo "→ adding $FIXTURE_DIR"
xcrun simctl addmedia "$UDID" "$FIXTURE_DIR"/*.JPG

xcrun simctl privacy "$UDID" grant photos "$BUNDLE_ID"
xcrun simctl privacy "$UDID" grant photos-add "$BUNDLE_ID"

echo
echo "UDID=$UDID"
echo "Run the benchmark with:"
echo "  TEST_RUNNER_BACKU_PERF=1 xcodebuild -project Backu.xcodeproj -scheme Backu \\"
echo "    -destination 'platform=iOS Simulator,id=$UDID' \\"
echo "    -only-testing:BackuUITests/ScrollPerformanceTests/testScrollPerformance \\"
echo "    -resultBundlePath /private/tmp/backu-perf-\$(date +%s) test"
