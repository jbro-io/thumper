#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
archive="Thumper-${version}-macOS-$(uname -m).zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent build/Thumper.app "build/$archive"
(
    cd build
    /usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
)
printf 'Release: %s/build/%s\n' "$PWD" "$archive"
