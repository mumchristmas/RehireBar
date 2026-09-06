#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_UPDATES=false
if [[ $# -gt 0 ]]; then
    [[ $# -eq 1 && "$1" == "--sign-updates" ]] || {
        echo "usage: $0 [--sign-updates]" >&2; exit 2;
    }
    SIGN_UPDATES=true
fi
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
OUTPUT="$ROOT/release"
mkdir -p "$OUTPUT"
# Rebuilt archives have new bytes. Never leave a feed advertising an old signature.
rm -f "$OUTPUT/appcast-arm64.xml" "$OUTPUT/appcast-x86_64.xml"

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
if [[ "$SIGN_UPDATES" == true ]]; then
    bash "$ROOT/scripts/generate-appcast.sh"
fi
