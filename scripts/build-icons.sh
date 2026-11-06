#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_icon="Resources/Artwork/ThumperIcon.png"
iconset="build/Thumper.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    /usr/bin/sips -z "$retina" "$retina" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$iconset" --output build/Thumper.icns
printf 'Built Thumper.icns (16–1024 px)\n'
