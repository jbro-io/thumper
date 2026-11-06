#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c release
app="$PWD/build/Thumper.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Thumper "$app/Contents/MacOS/Thumper"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
