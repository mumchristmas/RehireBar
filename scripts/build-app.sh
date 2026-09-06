#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Explicit selection prevents xcrun's shared cache from mixing an Xcode compiler
# with a separately updated Command Line Tools SDK.
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SWIFT_BIN="$(xcrun --find swift)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT="$SDK_PATH"
TARGET_ARCH="$(uname -m)"
DIST_DIR="$ROOT/dist"
TARGET_FLAGS=()
if [[ $# -gt 0 ]]; then
    if [[ $# -ne 2 || "$1" != "--arch" ]]; then
        echo "usage: $0 [--arch arm64|x86_64]" >&2
        exit 2
    fi
    case "$2" in
        arm64|x86_64) TARGET_ARCH="$2" ;;
        *) echo "Unsupported architecture: $2" >&2; exit 2 ;;
    esac
    MINIMUM_MACOS="$(plutil -extract LSMinimumSystemVersion raw "$ROOT/Resources/Info.plist")"
    TARGET_FLAGS=(--triple "$TARGET_ARCH-apple-macosx$MINIMUM_MACOS")
    DIST_DIR="$ROOT/dist/$TARGET_ARCH"
fi
DIST_APP="$DIST_DIR/RehireBar.app"
ARCHIVE="$DIST_DIR/RehireBar.zip"
BUILD_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rehirebar-build.XXXXXX")"
trap 'rm -rf "$BUILD_STAGE"' EXIT
APP="$BUILD_STAGE/RehireBar.app"
CONTENTS="$APP/Contents"

cd "$ROOT"
RELEASE_FLAGS=(-c release --sdk "$SDK_PATH" -Xswiftc -file-prefix-map -Xswiftc "$ROOT/Sources=Sources")
"$SWIFT_BIN" build "${RELEASE_FLAGS[@]}" ${TARGET_FLAGS[@]+"${TARGET_FLAGS[@]}"}
BIN_DIR="$("$SWIFT_BIN" build "${RELEASE_FLAGS[@]}" ${TARGET_FLAGS[@]+"${TARGET_FLAGS[@]}"} --show-bin-path)"
SPARKLE_ROOT="$ROOT/.build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Resolved Sparkle framework is missing" >&2; exit 1; }

rm -rf "$APP"
rm -f "$ARCHIVE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
mkdir -p "$DIST_DIR"
cp "$BIN_DIR/RehireBar" "$CONTENTS/MacOS/RehireBar"
# SwiftPM's release binary retains debug-map object paths. Strip those from the
# packaged copy before signing; the developer build and its symbols stay local.
xcrun strip -S "$CONTENTS/MacOS/RehireBar"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
FEED_BASE="$(plutil -extract SUFeedURL raw "$CONTENTS/Info.plist")"
FEED_BASE="${FEED_BASE%/*}"
plutil -replace SUFeedURL -string "$FEED_BASE/appcast-$TARGET_ARCH.xml" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Resources/ModelDisplay.json" "$CONTENTS/Resources/ModelDisplay.json"
cp "$ROOT/LICENSE" "$CONTENTS/Resources/LICENSE.txt"
cp "$ROOT/NOTICE.md" "$CONTENTS/Resources/NOTICE.md"
cp "$SPARKLE_ROOT/LICENSE" "$CONTENTS/Resources/Sparkle-LICENSE.txt"
COPYFILE_DISABLE=1 ditto --norsrc "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"
# Release tests use a private umask for diagnostics. Distributed applications
# still need normal read/traverse permissions when installed by another user.
chmod 755 "$APP" "$CONTENTS" "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
chmod 644 "$CONTENTS/Info.plist" "$CONTENTS/Resources/"*
chmod 755 "$CONTENTS/MacOS/RehireBar"

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP"
fi
if command -v codesign >/dev/null 2>&1; then
    if [[ -n "${REHIREBAR_SIGNING_IDENTITY:-}" ]]; then
        # Re-sign nested code inside out for the maintainer's distribution identity.
        # Ad-hoc development bundles retain Sparkle's original framework signature.
        SPARKLE_VERSION="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
        for component in \
            "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
            "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
            "$SPARKLE_VERSION/Autoupdate" \
            "$SPARKLE_VERSION/Updater.app" \
            "$CONTENTS/Frameworks/Sparkle.framework"; do
            codesign --force --sign "$REHIREBAR_SIGNING_IDENTITY" \
                --preserve-metadata=entitlements "$component"
        done
        codesign --force --sign "$REHIREBAR_SIGNING_IDENTITY" "$APP"
    else
        codesign --force --sign - "$APP"
    fi
    if command -v xattr >/dev/null 2>&1; then
        xattr -cr "$APP"
    fi
fi

# codesign can create CodeResources with the caller's private umask. Normalize
# every real bundle entry after signing, preserving executable bits and symlinks.
python3 - "$APP" <<'PY'
from pathlib import Path
import stat, sys
app = Path(sys.argv[1])
for entry in [app, *app.rglob('*')]:
    if entry.is_symlink():
        continue
    mode = stat.S_IMODE(entry.stat().st_mode)
    entry.chmod(0o755 if entry.is_dir() or mode & 0o111 else 0o644)
PY

rm -rf "$DIST_APP"
COPYFILE_DISABLE=1 ditto --norsrc "$APP" "$DIST_APP"
"$ROOT/scripts/verify-app.sh" "$DIST_APP" "$TARGET_ARCH"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"

echo "Built $DIST_APP"
echo "Built clean distributable archive $ARCHIVE"
