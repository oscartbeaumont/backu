#!/usr/bin/env bash
# Downloads the CC0 marketing photos used only for App Store screenshots.
set -euo pipefail
cd "$(dirname "$0")/../.."

DIR="Tests/Fixtures/marketing/raw"
mkdir -p "$DIR"

fetch() {
  local name="$1" title="$2"
  if [ -s "$DIR/$name" ] && file "$DIR/$name" | grep -q "image data"; then
    echo "  have $name"
    return
  fi
  local url="https://commons.wikimedia.org/wiki/Special:FilePath/$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$title")?width=1800"
  if curl -sfL -A "BackuAssets/1.0 (https://github.com/oscartbeaumont/backu)" -o "$DIR/$name" "$url" && file "$DIR/$name" | grep -q "image data"; then
    echo "  got  $name"
  else
    echo "  skip $name" >&2
    rm -f "$DIR/$name"
  fi
}

echo "→ Fetching CC0 marketing photos"
fetch asturias.jpg   "Mountains Landscape, Asturias, Spain, panoramic.jpg"
fetch greek-lake.jpg "Scenic landscape of Greek mountains and lake.jpg"
fetch phaistos.jpg   "Landscape mountains Phaistos.jpg"
fetch kerala.jpg     "Mountain landscape in kerala.jpg"
fetch dog-beach.jpg  "Dog at Nørre Vorupør Strand.jpg"
fetch dog-island.jpg "Dog in Chacachacare.jpg"
fetch cat-grass.jpg  "Domestic shorthair cat portrait in grass.jpg"
fetch cat-tabby.jpg  "Tabby cat with blue eyes-3336579.jpg"

swift Tools/Fixtures/prepare-marketing.swift
