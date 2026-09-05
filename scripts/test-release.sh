#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
BUILD_RELEASE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD_RELEASE=true; shift ;;
        --arch)
            [[ $# -ge 2 ]] || { echo "--arch needs arm64 or x86_64" >&2; exit 2; }
            ARCH="$2"; shift 2 ;;
        --help|-h)
            echo "usage: $0 [--build] [--arch arm64|x86_64]"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
if [[ "$BUILD_RELEASE" == true ]]; then
    bash "$ROOT/scripts/build-release.sh"
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$ROOT/Resources/Info.plist")"
RELEASE="$ROOT/release"
ARCHIVE="$RELEASE/RehireBar-$VERSION-macos-$ARCH.zip"
if [[ ! -f "$ARCHIVE" || ! -f "$RELEASE/SHA256SUMS" ]]; then
    echo "Release archive/checksums missing. Run: bash scripts/test-release.sh --build" >&2
    exit 1
fi
(cd "$RELEASE" && shasum -a 256 -c SHA256SUMS)
EXPECTED_SHA="$(awk -v file="RehireBar-$VERSION-macos-$ARCH.zip" '$2 == file { print $1 }' "$RELEASE/SHA256SUMS")"
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{ print $1 }')"
[[ -n "$EXPECTED_SHA" && "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || {
    echo "Selected archive does not match its release checksum" >&2; exit 1;
}

RUN_ROOT="$RELEASE/test"
RUN_DIR="$RUN_ROOT/$VERSION-$BUILD-$ARCH"
RUN_APP="$RUN_DIR/RehireBar.app"
STATUS_OUTPUT="$RUN_DIR/status.json"
mkdir -p "$RUN_ROOT"
STAGE="$(mktemp -d "$RUN_ROOT/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto -x -k "$ARCHIVE" "$STAGE"
bash "$ROOT/scripts/verify-app.sh" "$STAGE/RehireBar.app" "$ARCH"
codesign --verify --deep --strict "$STAGE/RehireBar.app"
[[ "$(plutil -extract CFBundleShortVersionString raw "$STAGE/RehireBar.app/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(plutil -extract CFBundleVersion raw "$STAGE/RehireBar.app/Contents/Info.plist")" == "$BUILD" ]]

# Only stop running app bundles with this exact product identity. Leave source
# trees, Downloads/Applications bundles, and unrelated processes on disk intact.
APP_ID="$(plutil -extract CFBundleIdentifier raw "$STAGE/RehireBar.app/Contents/Info.plist")"
STOPPED_PIDS=()
for pid in $(pgrep -x RehireBar || true); do
    binary="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    [[ "$binary" == */Contents/MacOS/RehireBar ]] || continue
    running_app="${binary%/Contents/MacOS/RehireBar}"
    identity="$(plutil -extract CFBundleIdentifier raw "$running_app/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$identity" == "$APP_ID" ]] || continue
    if [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == "$binary" ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        STOPPED_PIDS+=("$pid")
    fi
done
for pid in ${STOPPED_PIDS[@]+"${STOPPED_PIDS[@]}"}; do
    for _ in {1..50}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "Previous RehireBar process did not exit: $pid" >&2
        exit 1
    fi
done

if [[ -d "$RUN_DIR" ]]; then
    PREVIOUS="$(mktemp -d "$RUN_ROOT/previous.XXXXXX")"
    mv "$RUN_DIR" "$PREVIOUS/run"
fi
mkdir -p "$RUN_DIR"
mv "$STAGE/RehireBar.app" "$RUN_APP"
open -n "$RUN_APP" --args --status-output "$STATUS_OUTPUT"

RUN_PID=""
for _ in {1..100}; do
    for pid in $(pgrep -x RehireBar || true); do
        if [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == "$RUN_APP/Contents/MacOS/RehireBar" ]]; then
            RUN_PID="$pid"
            break
        fi
    done
    if [[ -n "$RUN_PID" && -s "$STATUS_OUTPUT" ]] &&
       grep -Eq "\"processID\"[[:space:]]*:[[:space:]]*$RUN_PID([,[:space:]]|$)" "$STATUS_OUTPUT"; then
        break
    fi
    sleep 0.1
done
if [[ -z "$RUN_PID" || ! -s "$STATUS_OUTPUT" ]] ||
   ! grep -Eq "\"processID\"[[:space:]]*:[[:space:]]*$RUN_PID([,[:space:]]|$)" "$STATUS_OUTPUT"; then
    echo "Release app did not publish a monitoring snapshot: $RUN_APP" >&2
    exit 1
fi
kill -0 "$RUN_PID"
codesign --verify --deep --strict "$RUN_APP"
{
    printf 'Version: %s (build %s)\nArchitecture: %s\nPID: %s\n' "$VERSION" "$BUILD" "$ARCH" "$RUN_PID"
    printf 'App: %s\nArchive: %s\nMonitoring snapshot: %s\n' "$RUN_APP" "$ARCHIVE" "$STATUS_OUTPUT"
    printf 'Verified at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    shasum -a 256 "$RUN_APP/Contents/MacOS/RehireBar"
} > "$RUN_ROOT/LAST-RUN.txt"
cat "$RUN_ROOT/LAST-RUN.txt"
