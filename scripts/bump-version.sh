#!/usr/bin/env bash
# Computes the next marketing version and writes it into project.yml.
#
# Usage:
#   ./scripts/bump-version.sh [patch|minor|major] [explicit-version]
#
# The first release (no v* tags yet) keeps the version currently in
# project.yml, normalised to three components, so a fresh repository starts at
# 1.0.0. After that, patch/minor/major bump the latest v* tag. An explicit
# version overrides the bump and is useful for a deliberate 1.2.0 release.
#
# Prints the chosen version on stdout. Diagnostics go to stderr so the output
# can be captured by CI.
set -euo pipefail
cd "$(dirname "$0")/.."

BUMP="${1:-patch}"
EXPLICIT="${2:-}"

case "$BUMP" in
  patch|minor|major) ;;
  *)
    echo "bump must be patch, minor or major (got '$BUMP')" >&2
    exit 2
    ;;
esac

normalize() {
  local raw="${1#v}"
  local major=0 minor=0 patch=0 extra=""
  IFS=. read -r major minor patch extra <<< "$raw" || true
  major=${major:-0}
  minor=${minor:-0}
  patch=${patch:-0}
  printf '%d.%d.%d' "$((10#$major))" "$((10#$minor))" "$((10#$patch))"
}

is_complete_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

current_raw="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -n 1)"
if [ -z "$current_raw" ]; then
  echo "could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi
current="$(normalize "$current_raw")"

latest_tag="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n 1 || true)"
base="$current"
if [ -n "$latest_tag" ]; then
  base="$(normalize "$latest_tag")"
fi

if [ -n "$EXPLICIT" ]; then
  candidate="${EXPLICIT#v}"
  if ! is_complete_version "$candidate"; then
    echo "explicit version must look like 1.2.3 (got '$EXPLICIT')" >&2
    exit 2
  fi
  next="$(normalize "$candidate")"
elif [ -z "$latest_tag" ]; then
  # A brand-new project has no release yet. Publish the version already in the
  # repository rather than jumping to 1.0.1 on the first patch release.
  next="$current"
else
  next="$(normalize "$base")"
  IFS=. read -r major minor patch <<< "$next" || true
  case "$BUMP" in
    major) next="$((major + 1)).0.0" ;;
    minor) next="$major.$((minor + 1)).0" ;;
    patch) next="$major.$minor.$((patch + 1))" ;;
  esac
fi

if git rev-parse -q --verify "refs/tags/v$next" >/dev/null; then
  echo "tag v$next already exists" >&2
  exit 1
fi

# Update only the one setting XcodeGen reads. The tracked .xcodeproj is not
# committed; CI regenerates it from this file.
perl -0pi -e 's/(MARKETING_VERSION:\s*")[^"]+(")/${1}'"$next"'${2}/' project.yml

if ! grep -q "MARKETING_VERSION: \"$next\"" project.yml; then
  echo "failed to write MARKETING_VERSION to project.yml" >&2
  exit 1
fi

printf '%s\n' "$next"
