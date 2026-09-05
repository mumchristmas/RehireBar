#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
OUTPUT="$ROOT/release"
mkdir -p "$OUTPUT"

for architecture in arm64 x86_64; do
    bash "$ROOT/scripts/build-app.sh" --arch "$architecture"
    cp "$ROOT/dist/$architecture/RehireBar.zip" \
        "$OUTPUT/RehireBar-$VERSION-macos-$architecture.zip"
done

cd "$OUTPUT"
shasum -a 256 "RehireBar-$VERSION-macos-arm64.zip" \
    "RehireBar-$VERSION-macos-x86_64.zip" > SHA256SUMS
shasum -a 256 -c SHA256SUMS
echo "Release archives and checksums: $OUTPUT"
