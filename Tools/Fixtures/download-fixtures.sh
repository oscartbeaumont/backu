#!/usr/bin/env bash
# Downloads the public-domain / CC test photos used by Tools/Fixtures.
# They are not committed, so a fresh clone runs this once before preparing the
# simulator library. See Tests/Fixtures/ATTRIBUTION.md for sources and licences.
set -euo pipefail
cd "$(dirname "$0")/../.."

DIR="Tests/Fixtures/raw"
mkdir -p "$DIR"

fetch() {
  local name="$1" file="$2"
  if [ -s "$DIR/$name" ] && file "$DIR/$name" | grep -q "image data"; then
    echo "  have $name"
    return
  fi
  local url="https://commons.wikimedia.org/wiki/Special:FilePath/${file}?width=1600"
  for attempt in 1 2 3; do
    if curl -sfL -A "BackuFixtures/1.0 (https://github.com/oscartbeaumont/backu)" \
        -o "$DIR/$name" "$url" && file "$DIR/$name" | grep -q "image data"; then
      echo "  got  $name"
      return
    fi
    sleep "$attempt"
  done
  echo "  skip $name (download failed)" >&2
  rm -f "$DIR/$name"
}

echo "→ Fetching fixtures into $DIR"
fetch obama.jpg       "President_Barack_Obama.jpg"
fetch obama-2.jpg     "Official_portrait_of_Barack_Obama.jpg"
fetch michelle.jpg    "Michelle_Obama_2013_official_portrait.jpg"
fetch biden.jpg       "Joe_Biden_presidential_portrait.jpg"
fetch harris.jpg      "Kamala_Harris_Vice_Presidential_Portrait.jpg"
fetch jemison.jpg     "Mae_Jemison.jpg"
fetch two-people.jpg  "Barack_Obama_and_Joe_Biden_in_the_Oval_Office_-_2015.jpg"
fetch golden.jpg      "Golden_Retriever_Carlos_(10581910556).jpg"
fetch dog-2.jpg       "Dülmen,_Hausdülmen,_Golden_Retriever_--_2022_--_5530.jpg"

echo "Done."
