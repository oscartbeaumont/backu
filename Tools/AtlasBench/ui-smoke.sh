#!/usr/bin/env bash
# End-to-end before/after against a simulator: seed two buckets with the same
# remote-only library, one with atlas pointers and one without, open each in the
# real app, and count what the bucket actually served.
#
#   ./Tools/AtlasBench/ui-smoke.sh
#
# The interesting number is per-photo GETs. Both launches load a few 1,200 px
# viewer previews, so compare the cases rather than expecting a literal zero.
set -euo pipefail
cd "$(dirname "$0")/../.."

BASE_PORT="${BACKU_ATLAS_SMOKE_PORT:-9400}"
PHOTOS="${BACKU_ATLAS_SMOKE_PHOTOS:-300}"
DEVICE_NAME="${BACKU_ATLAS_DEVICE:-iPhone 17 Pro}"
WORK="${TMPDIR:-/tmp}/backu-atlas-smoke"
APP="${BACKU_ATLAS_APP:-/private/tmp/backu-atlas-derived/Build/Products/Debug-iphonesimulator/Backu.app}"
BENCH="${BACKU_ATLAS_BIN:-/tmp/backu-atlas-bench}"

mkdir -p "$WORK"

echo "→ Building $BENCH"
swiftc -O -o "$BENCH" \
  Sources/Core/Models/StorageProvider.swift \
  Sources/Core/Models/ServerConfig.swift \
  Sources/Core/Models/PhotoItem.swift \
  Sources/Core/Models/Person.swift \
  Sources/Core/S3/*.swift \
  Sources/Core/Library/ThumbnailAtlas.swift \
  Sources/Core/Storage/AppPaths.swift \
  Sources/Core/Sync/Sidecar.swift \
  Tools/AtlasBench/main.swift

if [[ ! -d "$APP" ]]; then
  echo "→ Building the app (BACKU_ATLAS_APP overrides the path)"
  xcodegen generate >/dev/null
  xcodebuild -project Backu.xcodeproj -scheme Backu \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /private/tmp/backu-atlas-derived \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
fi

UDID="$(xcrun simctl list devices available | sed -n "s/^    ${DEVICE_NAME} (\([0-9A-F-]*\)) (.*/\1/p" | head -1)"
if [[ -z "$UDID" ]]; then
  echo "No '$DEVICE_NAME' simulator. Set BACKU_ATLAS_DEVICE." >&2
  exit 1
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant photos me.otbeaumont.backu

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

start_bucket() {
  local port="$1"
  shift
  pkill -f "mock_s3.py.*--port $port" 2>/dev/null || true
  rm -rf "$WORK/s3-$port" && mkdir -p "$WORK/s3-$port"
  python3 Tools/MockS3/mock_s3.py --port "$port" --data-dir "$WORK/s3-$port" \
    >"$WORK/mock-$port.log" 2>&1 &
  PIDS+=("$!")
  sleep 1
  echo "→ Seeding port $port"
  "$BENCH" --mode network --endpoint "http://127.0.0.1:$port" --photos "$PHOTOS" \
    --runs 1 --prefix "ui-$port" --seed-index "$@" \
    --corpus "Tests/Fixtures/atlas-corpus" >/dev/null
}

launch_case() {
  local port="$1"
  local log="$WORK/mock-$port.log"
  local boot
  boot="{\"servers\":[{\"name\":\"Atlas\",\"provider\":\"custom\",\"endpoint\":\"http://127.0.0.1:$port\",\"region\":\"us-east-1\",\"bucket\":\"backu-test\",\"accessKeyID\":\"testkey\",\"secretAccessKey\":\"testsecret\",\"pathStyle\":true,\"prefix\":\"\"}],\"settings\":{\"autoBackupEnabled\":false,\"backupOnCellular\":false,\"faceRecognitionEnabled\":false,\"gridColumns\":3,\"hasCompletedOnboarding\":true,\"showRemoteOnlyPhotos\":true}}"
  # A reinstall is the only reliable reset for app data, Keychain and any
  # cached sheets left by an earlier case.
  xcrun simctl terminate "$UDID" me.otbeaumont.backu >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" me.otbeaumont.backu >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl privacy "$UDID" grant photos me.otbeaumont.backu
  : > "$log"
  SIMCTL_CHILD_BACKU_RESET=1 SIMCTL_CHILD_BACKU_BOOTSTRAP="$boot" \
    xcrun simctl launch "$UDID" me.otbeaumont.backu >/dev/null
  sleep 10
  local photo grid preview
  photo=$(grep -ac "ui-$port/current-900" "$log" || true)
  grid=$(grep -ac 'atlas/v1/grid/' "$log" || true)
  preview=$(grep -ac 'atlas/v1/preview/' "$log" || true)
  printf '  %-10s per-photo %4s   grid sheets %3s   preview sheets %3s\n' "$2" "$photo" "$grid" "$preview"
  echo "    first requests:"; grep -a "GET" "$log" | head -3 | sed 's/^/      /'
  C=$(xcrun simctl get_app_container "$UDID" me.otbeaumont.backu data 2>/dev/null || true)
  if [[ -n "$C" ]]; then echo "    servers: $(cat "$C/Library/Application Support/Backu/servers.json" 2>/dev/null | head -c 300)"; fi
  echo "$photo $grid $preview" > "$WORK/result-$2"
}

BASELINE_PORT=$((BASE_PORT + 1))
start_bucket "$BASE_PORT"
start_bucket "$BASELINE_PORT" --no-atlas

echo
echo "→ Same 300-photo remote library, two buckets, real app, 10 s after launch"
launch_case "$BASELINE_PORT" baseline
launch_case "$BASE_PORT" atlas

read -r BASE_PHOTO _ < "$WORK/result-baseline"
read -r ATLAS_PHOTO _ < "$WORK/result-atlas"
echo
if [[ "$ATLAS_PHOTO" -ge "$BASE_PHOTO" ]]; then
  echo "Atlases did not reduce per-photo requests ($BASE_PHOTO -> $ATLAS_PHOTO)." >&2
  exit 1
fi
echo "Per-photo requests fell from $BASE_PHOTO to $ATLAS_PHOTO."
