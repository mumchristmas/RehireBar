#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${1:-$ROOT/dist/RehireBar.app}"
EXPECTED_ARCH="${2:-}"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "App bundle not found: $SOURCE_APP" >&2
    exit 1
fi
if ! command -v codesign >/dev/null 2>&1; then
    echo "codesign is required to verify the app bundle" >&2
    exit 1
fi

STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rehirebar-verify.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGED_APP="$STAGE_ROOT/RehireBar.app"

COPYFILE_DISABLE=1 ditto --norsrc "$SOURCE_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
for directory in "$STAGED_APP" "$STAGED_APP/Contents" "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Frameworks"; do
    if [[ "$(stat -f '%Lp' "$directory")" != "755" ]]; then
        echo "App directory has non-distributable permissions: $directory" >&2
        exit 1
    fi
done
for resource in "$STAGED_APP/Contents/Info.plist" "$STAGED_APP/Contents/Resources/"*; do
    if [[ "$(stat -f '%Lp' "$resource")" != "644" ]]; then
        echo "App resource has non-distributable permissions: $resource" >&2
        exit 1
    fi
done
EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw "$STAGED_APP/Contents/Info.plist")"
EXECUTABLE="$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Declared app executable is missing or not executable" >&2
    exit 1
fi
ACTUAL_ARCH="$(lipo -archs "$EXECUTABLE")"
if [[ -n "$EXPECTED_ARCH" && "$ACTUAL_ARCH" != "$EXPECTED_ARCH" ]]; then
    echo "Architecture mismatch: expected $EXPECTED_ARCH, found $ACTUAL_ARCH" >&2
    exit 1
fi
if LC_ALL=C grep -aEq '/Users/[^/[:space:]]+/|/home/[^/[:space:]]+/' "$EXECUTABLE"; then
    echo "Packaged binary contains a private home-directory path; rebuild with build-app.sh" >&2
    exit 1
fi
ICON_NAME="$(plutil -extract CFBundleIconFile raw "$STAGED_APP/Contents/Info.plist")"
if [[ ! -f "$STAGED_APP/Contents/Resources/${ICON_NAME}.icns" ]]; then
    echo "Declared app icon is missing: ${ICON_NAME}.icns" >&2
    exit 1
fi
if [[ ! -f "$STAGED_APP/Contents/Resources/ModelDisplay.json" ]]; then
    echo "Bundled model display configuration is missing" >&2
    exit 1
fi
for notice in LICENSE.txt NOTICE.md Sparkle-LICENSE.txt; do
    if [[ ! -s "$STAGED_APP/Contents/Resources/$notice" ]]; then
        echo "Bundled license or attribution is missing: $notice" >&2
        exit 1
    fi
done

SPARKLE="$STAGED_APP/Contents/Frameworks/Sparkle.framework"
if [[ ! -L "$SPARKLE/Versions/Current" || ! -x "$SPARKLE/Sparkle" ]]; then
    echo "Sparkle framework or its required symlinks are missing" >&2
    exit 1
fi
for architecture in $ACTUAL_ARCH; do
    lipo "$SPARKLE/Sparkle" -verify_arch "$architecture"
done
otool -L "$EXECUTABLE" | grep -Fq '@rpath/Sparkle.framework/' || {
    echo "Executable does not link the bundled updater framework" >&2; exit 1;
}
python3 - "$STAGED_APP/Contents/Info.plist" "$ACTUAL_ARCH" <<'PY'
import base64, plistlib, stat, sys
from pathlib import Path
from urllib.parse import urlparse
app = Path(sys.argv[1]).parent.parent
for entry in [app, *app.rglob('*')]:
    if entry.is_symlink():
        continue
    mode = stat.S_IMODE(entry.stat().st_mode)
    expected = 0o755 if entry.is_dir() or mode & 0o111 else 0o644
    assert mode == expected, (str(entry.relative_to(app)), oct(mode))
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
url = urlparse(info['SUFeedURL'])
assert url.scheme == 'https' and url.hostname and not url.username and not url.password
assert url.path.endswith('/appcast-' + sys.argv[2] + '.xml')
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
for setting in ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling'):
    assert info.get(setting) is False, setting
for setting in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
    assert info.get(setting) is True, setting
assert info.get('SUSignedFeedFailureExpirationInterval') == 0
PY

echo "Verified clean staged copy ($ACTUAL_ARCH): $STAGED_APP"
