#!/usr/bin/env bash
# Copies the four TestFlight values into GitHub Actions repository secrets.
#
# Required environment:
#   ASC_KEY_ID     App Store Connect API key ID (10 characters)
#   ASC_ISSUER_ID  App Store Connect issuer UUID
#
# Optional:
#   APPLE_TEAM_ID  defaults to 68994Z5PT3
#   REPO           owner/name; defaults to the current gh repository
#
# Usage:
#   ./scripts/set-testflight-secrets.sh ~/Downloads/AuthKey_XXXXXXXXXX.p8
set -euo pipefail

KEY_PATH="${1:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-68994Z5PT3}"
: "${ASC_KEY_ID:?export ASC_KEY_ID (App Store Connect API key ID)}"
: "${ASC_ISSUER_ID:?export ASC_ISSUER_ID (App Store Connect issuer UUID)}"

[ -n "$KEY_PATH" ] || {
  echo "usage: $0 /path/to/AuthKey_<KEY_ID>.p8" >&2
  exit 2
}
[ -f "$KEY_PATH" ] || { echo "key not found: $KEY_PATH" >&2; exit 2; }
[ "$(basename "$KEY_PATH")" = "AuthKey_${ASC_KEY_ID}.p8" ] || {
  echo "filename must be AuthKey_${ASC_KEY_ID}.p8" >&2
  exit 2
}
grep -q "BEGIN PRIVATE KEY" "$KEY_PATH" || {
  echo "$KEY_PATH does not look like an App Store Connect .p8 key" >&2
  exit 2
}
[[ "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "ASC_KEY_ID must be 10 uppercase letters/digits" >&2
  exit 2
}
[[ "$ASC_ISSUER_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || {
  echo "ASC_ISSUER_ID must be a UUID" >&2
  exit 2
}
command -v gh >/dev/null || { echo "gh CLI is required" >&2; exit 2; }
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

printf '%s' "$APPLE_TEAM_ID" | gh secret set APPLE_TEAM_ID --repo "$REPO"
printf '%s' "$ASC_KEY_ID" | gh secret set ASC_KEY_ID --repo "$REPO"
printf '%s' "$ASC_ISSUER_ID" | gh secret set ASC_ISSUER_ID --repo "$REPO"
gh secret set ASC_PRIVATE_KEY --repo "$REPO" < "$KEY_PATH"

echo "Set TestFlight secrets on $REPO:"
echo "  APPLE_TEAM_ID=$APPLE_TEAM_ID"
echo "  ASC_KEY_ID=$ASC_KEY_ID"
echo "  ASC_ISSUER_ID=$ASC_ISSUER_ID"
echo "  ASC_PRIVATE_KEY=(contents of $(basename "$KEY_PATH"))"
