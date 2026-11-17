#!/usr/bin/env bash
# Archives, signs and uploads a TestFlight build using an App Store Connect API
# key. The API key needs the Admin role so xcodebuild can create the cloud-managed
# distribution certificate and provisioning profile on the fly. App Manager keys
# can upload, but cannot create distribution signing assets from CI.
#
# Required environment:
#   APPLE_TEAM_ID        e.g. 68994Z5PT3
#   ASC_KEY_ID           App Store Connect API key ID (10 characters)
#   ASC_ISSUER_ID        App Store Connect issuer UUID
#   ASC_KEY_PATH         path to AuthKey_<KEY>.p8
#
# Optional:
#   BUILD_NUMBER         defaults to a UTC timestamp; must increase per upload
#   MARKETING_VERSION    defaults to MARKETING_VERSION in project.yml
#   PLATFORM             ios (default) or macos
#   SKIP_UPLOAD=1        build and export only, do not upload
#   KEYCHAIN_PATH        keychain to unlock in CI (optional)
#
# The app record and bundle ID must already exist in App Store Connect. The
# script cannot create the record: that needs the account owner.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID (Apple Developer team ID)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API key ID)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect issuer ID)}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH (path to AuthKey_<id>.p8)}"

BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
if [ -z "${MARKETING_VERSION:-}" ]; then
  MARKETING_VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -n 1)"
fi
MARKETING_VERSION="${MARKETING_VERSION:-1.0}"
PLATFORM="${PLATFORM:-ios}"

case "$PLATFORM" in
  ios)
    DESTINATION="generic/platform=iOS"
    ALT_TYPE="ios"
    ARTIFACT_EXT="ipa"
    ;;
  macos)
    DESTINATION="generic/platform=macOS"
    ALT_TYPE="macos"
    ARTIFACT_EXT="pkg"
    ;;
  *)
    echo "PLATFORM must be 'ios' or 'macos', got '$PLATFORM'" >&2
    exit 2
    ;;
esac

OUT="build/testflight-${PLATFORM}"
ARCHIVE="$OUT/Backu.xcarchive"
EXPORT="$OUT/export"

for tool in xcodegen xcodebuild xcrun; do
  command -v "$tool" >/dev/null || { echo "missing $tool"; exit 1; }
done
[ -f "$ASC_KEY_PATH" ] || { echo "API key not found at $ASC_KEY_PATH"; exit 1; }

echo "→ Generating the project"
xcodegen generate >/dev/null

echo "→ Archiving Backu $MARKETING_VERSION ($BUILD_NUMBER) for $PLATFORM"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"
xcodebuild -project Backu.xcodeproj -scheme Backu \
  -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  archive

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$APPLE_TEAM_ID</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <true/>
</dict>
</plist>
PLIST

echo "→ Exporting the App Store artifact"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

ARTIFACT=$(find "$EXPORT" -maxdepth 1 -name "*.$ARTIFACT_EXT" | head -1)
[ -n "$ARTIFACT" ] || { echo "no .$ARTIFACT_EXT produced in $EXPORT"; exit 1; }
echo "Artifact: $ARTIFACT"

if [ "${SKIP_UPLOAD:-0}" = "1" ]; then
  echo "SKIP_UPLOAD=1, leaving the artifact for manual upload."
  exit 0
fi

KEY_DIR=$(mktemp -d)
trap 'rm -rf "$KEY_DIR"' EXIT
cp "$ASC_KEY_PATH" "$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
chmod 600 "$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
export API_PRIVATE_KEYS_DIR="$KEY_DIR"

echo "→ Validating with App Store Connect"
xcrun altool --validate-app -f "$ARTIFACT" -t "$ALT_TYPE" \
  --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

echo "→ Uploading to TestFlight"
xcrun altool --upload-app -f "$ARTIFACT" -t "$ALT_TYPE" \
  --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

cat <<EOF

Uploaded Backu $MARKETING_VERSION ($BUILD_NUMBER) for $PLATFORM.
Open App Store Connect → TestFlight to watch processing, add testers, and
answer the export-compliance prompt if it appears.
EOF
