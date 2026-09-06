#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$TOOLS/generate_appcast" ]] || {
    echo "Build the release archives before generating signed updates." >&2; exit 1;
}
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$ROOT/Resources/Info.plist")"
EXPECTED_KEY="$(plutil -extract SUPublicEDKey raw "$ROOT/Resources/Info.plist")"
ACCOUNT="${REHIREBAR_UPDATE_KEY_ACCOUNT:-com.bigbom.RehireBar.updates}"
REPOSITORY="${REHIREBAR_RELEASE_REPOSITORY:-mumchristmas/RehireBar}"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid release repository" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || {
    echo "Release version/build must be numeric and monotonically increasing." >&2; exit 2;
}
SIGNING=(--account "$ACCOUNT")
if [[ -n "${REHIREBAR_SPARKLE_KEY_FILE:-}" ]]; then
    SIGNING=(--ed-key-file "$REHIREBAR_SPARKLE_KEY_FILE")
    PUBLIC_KEY="$(xcrun swift "$ROOT/scripts/update-key-public.swift" "$REHIREBAR_SPARKLE_KEY_FILE")"
else
    PUBLIC_KEY="$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)"
fi
[[ "$PUBLIC_KEY" == "$EXPECTED_KEY" ]] || {
    echo "Signing key does not match the public key embedded in this app. No feed was generated." >&2
    exit 1
}

RELEASE="$ROOT/release"
(cd "$RELEASE" && shasum -a 256 -c SHA256SUMS)
python3 - "$ROOT/Resources/Info.plist" "$RELEASE" <<'PY'
import plistlib, struct, sys, zipfile
from pathlib import Path
source = plistlib.loads(Path(sys.argv[1]).read_bytes())
for arch, cpu in [('arm64', 0x0100000C), ('x86_64', 0x01000007)]:
    path = Path(sys.argv[2]) / f"RehireBar-{source['CFBundleShortVersionString']}-macos-{arch}.zip"
    with zipfile.ZipFile(path) as archive:
        item = archive.getinfo('RehireBar.app/Contents/Info.plist')
        assert item.file_size <= 65536
        actual = plistlib.loads(archive.read(item))
        for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleVersion', 'CFBundleShortVersionString', 'SUPublicEDKey'):
            assert actual[key] == source[key], (arch, key)
        assert actual['SUFeedURL'].endswith('/appcast-' + arch + '.xml')
        for key in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
            assert actual.get(key) is True, (arch, key)
        with archive.open('RehireBar.app/Contents/MacOS/RehireBar') as executable:
            magic, cputype = struct.unpack('<II', executable.read(8))
        assert magic == 0xfeedfacf and cputype == cpu, arch
PY
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rehirebar-appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
for architecture in arm64 x86_64; do
    NAME="RehireBar-$VERSION-macos-$architecture"
    ARCHIVE="$RELEASE/$NAME.zip"
    [[ -f "$ARCHIVE" ]] || { echo "Release archive is missing: $NAME.zip" >&2; exit 1; }
    mkdir -p "$STAGE/$architecture"
    cp "$ARCHIVE" "$STAGE/$architecture/$NAME.zip"
    if [[ -f "$RELEASE/RELEASE-NOTES-$VERSION.md" ]]; then
        cp "$RELEASE/RELEASE-NOTES-$VERSION.md" "$STAGE/$architecture/$NAME.md"
    fi
    "$TOOLS/generate_appcast" "${SIGNING[@]}" \
        --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
        --link "https://github.com/$REPOSITORY/releases/tag/v$VERSION" \
        --versions "$BUILD" --maximum-versions 1 --maximum-deltas 0 --embed-release-notes \
        -o "$STAGE/$architecture/appcast-$architecture.xml" "$STAGE/$architecture"
    "$TOOLS/sign_update" "${SIGNING[@]}" --verify "$STAGE/$architecture/appcast-$architecture.xml"
    python3 - "$STAGE/$architecture/appcast-$architecture.xml" "$VERSION" "$BUILD" "$REPOSITORY" "$NAME" "$ARCHIVE" <<'PY'
import base64, sys, xml.etree.ElementTree as ET
from pathlib import Path
feed, version, build, repository, name, archive = sys.argv[1:]
namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(feed).findall('./channel/item')
assert len(items) == 1
item = items[0]
assert item.findtext('sparkle:version', namespaces=namespace) == build
assert item.findtext('sparkle:shortVersionString', namespaces=namespace) == version
enclosure = item.find('enclosure')
assert enclosure is not None
assert enclosure.get('url') == f'https://github.com/{repository}/releases/download/v{version}/{name}.zip'
assert int(enclosure.get('length')) == Path(archive).stat().st_size
signature = enclosure.get('{'+namespace['sparkle']+'}edSignature')
assert len(base64.b64decode(signature, validate=True)) == 64
PY
done

# Copy only after both feeds passed signing verification. Key files are never copied.
for architecture in arm64 x86_64; do
    cp "$STAGE/$architecture/appcast-$architecture.xml" "$RELEASE/appcast-$architecture.xml"
done
cd "$RELEASE"
shasum -a 256 "RehireBar-$VERSION-macos-arm64.zip" \
    "RehireBar-$VERSION-macos-x86_64.zip" appcast-arm64.xml appcast-x86_64.xml > SHA256SUMS
shasum -a 256 -c SHA256SUMS
echo "Signed architecture-specific update feeds are ready in release/."
