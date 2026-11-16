#!/usr/bin/env bash
# Boots a simulator with sample photos and a live mock S3 bucket, installs Backu
# and launches it already configured. Useful for hands-on review of every flow
# without typing credentials on a simulator keyboard.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${BACKU_SIM:-iPhone 17 Pro}"
BUNDLE="dev.oscartbeaumont.backu"
PORT="${BACKU_PORT:-9000}"
DATA_DIR="${BACKU_BUCKET_DIR:-/private/tmp/backu-s3}"

command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen"; exit 1; }

echo "→ Generating the Xcode project"
xcodegen generate >/dev/null

echo "→ Preparing a sample library with EXIF"
swift Tools/Fixtures/prepare-fixtures.swift >/dev/null

echo "→ Starting the mock bucket on :$PORT"
pkill -f "mock_s3.py.*--data-dir $DATA_DIR" 2>/dev/null || true
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"
python3 Tools/MockS3/mock_s3.py --data-dir "$DATA_DIR" --port "$PORT" >/tmp/backu-mock-s3.log 2>&1 &
sleep 1

echo "→ Booting $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

echo "→ Building"
xcodebuild -project Backu.xcodeproj -scheme Backu \
  -destination "platform=iOS Simulator,name=$DEVICE" -configuration Debug build >/dev/null

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*Build/Products/Debug-iphonesimulator/Backu.app' -maxdepth 6 | head -1)
xcrun simctl install "$DEVICE" "$APP"

echo "→ Seeding photos and permissions"
xcrun simctl addmedia "$DEVICE" Tests/Fixtures/library/*.JPG
xcrun simctl privacy "$DEVICE" grant photos "$BUNDLE" 2>/dev/null || true

BOOTSTRAP=$(cat <<JSON
{"servers":[{"name":"Local Test","provider":"custom","endpoint":"http://127.0.0.1:$PORT","region":"us-east-1","bucket":"backu-test","accessKeyID":"testkey","secretAccessKey":"testsecret","pathStyle":true,"prefix":"Backu"}],
 "settings":{"autoBackupEnabled":false,"backupOnCellular":true,"faceRecognitionEnabled":true,"gridColumns":3,"hasCompletedOnboarding":true}}
JSON
)

echo "→ Launching Backu"
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
SIMCTL_CHILD_BACKU_RESET=1 SIMCTL_CHILD_BACKU_BOOTSTRAP="$BOOTSTRAP" \
  xcrun simctl launch "$DEVICE" "$BUNDLE"

cat <<EOF

Backu is running on "$DEVICE".
Mock bucket: http://127.0.0.1:$PORT  (bucket backu-test, key testkey / testsecret)
Uploads land in: $DATA_DIR
Logs: /tmp/backu-mock-s3.log

To see another device's library, launch the Mac app with the same bootstrap:
  BACKU_RESET=1 BACKU_BOOTSTRAP='$BOOTSTRAP' \\
    "$(dirname "$APP")/../../Debug/Backu.app/Contents/MacOS/Backu"
EOF
