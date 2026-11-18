#!/usr/bin/env bash
# Opens a v2 bucket in the real app on a simulator and checks that the log is
# what populated the library. Seeds one snapshot + one segment, launches with a
# bootstrapped server, then inspects the catalog the app wrote.
#
#   ./Tools/MetaBench/smoke.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT="${BACKU_META_SMOKE_PORT:-9500}"
PHOTOS="${BACKU_META_SMOKE_PHOTOS:-500}"
DEVICE_NAME="${BACKU_META_SMOKE_DEVICE:-iPhone 17 Pro}"
PREFIX="${BACKU_META_SMOKE_PREFIX:-MetaSeed}"
WORK="${TMPDIR:-/tmp}/backu-meta-smoke"
BENCH="${BACKU_META_BENCH_BIN:-/tmp/backu-meta-bench}"
APP="${BACKU_META_APP:-/private/tmp/backu-meta-derived/Build/Products/Debug-iphonesimulator/Backu.app}"

mkdir -p "$WORK"
[[ -x "$BENCH" ]] || ./Tools/MetaBench/run.sh >/dev/null

if [[ ! -d "$APP" ]]; then
  echo "→ Building the app (BACKU_META_APP overrides the path)"
  xcodegen generate >/dev/null
  xcodebuild -project Backu.xcodeproj -scheme Backu \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /private/tmp/backu-meta-derived \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
fi

pkill -f "mock_s3.py.*--port $PORT" 2>/dev/null || true
rm -rf "$WORK/s3" && mkdir -p "$WORK/s3"
python3 Tools/MockS3/mock_s3.py --port "$PORT" --data-dir "$WORK/s3" \
  >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
sleep 1

echo "→ Seeding $PHOTOS photos into $PREFIX"
"$BENCH" --photos "$PHOTOS" --edits 5 \
  --endpoint "http://127.0.0.1:$PORT" \
  --seed --seed-prefix "$PREFIX" >/dev/null

UDID="$(xcrun simctl list devices available | sed -n "s/^    ${DEVICE_NAME} (\([0-9A-F-]*\)) (.*/\1/p" | head -1)"
if [[ -z "$UDID" ]]; then
  echo "No '$DEVICE_NAME' simulator. Set BACKU_META_SMOKE_DEVICE." >&2
  exit 1
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl uninstall "$UDID" me.otbeaumont.backu >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant photos me.otbeaumont.backu

BOOT="{\"servers\":[{\"name\":\"Meta\",\"provider\":\"custom\",\"endpoint\":\"http://127.0.0.1:$PORT\",\"region\":\"us-east-1\",\"bucket\":\"backu-test\",\"accessKeyID\":\"testkey\",\"secretAccessKey\":\"testsecret\",\"pathStyle\":true,\"prefix\":\"$PREFIX\"}],\"settings\":{\"autoBackupEnabled\":false,\"backupOnCellular\":false,\"faceRecognitionEnabled\":false,\"gridColumns\":3,\"hasCompletedOnboarding\":true,\"showRemoteOnlyPhotos\":true}}"

: > "$WORK/mock.log"
SIMCTL_CHILD_BACKU_RESET=1 SIMCTL_CHILD_BACKU_BOOTSTRAP="$BOOT" \
  xcrun simctl launch "$UDID" me.otbeaumont.backu >/dev/null
sleep 12

CONTAINER="$(xcrun simctl get_app_container "$UDID" me.otbeaumont.backu data)"
CATALOG="$CONTAINER/Library/Application Support/Backu/catalog.json"

HEAD=$(grep -ac 'head.json' "$WORK/mock.log" || true)
SNAP=$(grep -ac '/snap/' "$WORK/mock.log" || true)
SEG=$(grep -ac '/log/' "$WORK/mock.log" || true)
LEGACY=$(grep -ac 'index.json' "$WORK/mock.log" || true)

echo
echo "  head GETs        $HEAD"
echo "  snapshot GETs    $SNAP"
echo "  segment GETs     $SEG"
echo "  legacy index     $LEGACY   (must be 0)"
python3 - "$CATALOG" "$PHOTOS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
photos = data.get("photos", [])
remote = [p for p in photos if not p.get("localIdentifier")]
expected = int(sys.argv[2])
print(f"  catalog          {len(photos)} photos ({len(remote)} remote), expected {expected}")
if len(photos) != expected:
    raise SystemExit("The app did not import exactly the seeded library")
assert not any("/index.json" in p.get("remoteThumbnailKey", "") for p in photos)
PY

if [[ "$LEGACY" -ne 0 ]]; then
  echo "The app fell back to the legacy index; v2 was not used." >&2
  exit 1
fi
echo
echo "The v2 head, snapshot and segment populated the app without index.json."
