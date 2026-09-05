#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-release}"
APP_NAME="RehireBar"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/RehireBar.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/RehireBar"

if [[ "$MODE" == "release" ]]; then
    exec bash "$ROOT_DIR/scripts/test-release.sh" --build
fi

if [[ -d "$HOME/Downloads/Xcode-beta.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode-beta.app/Contents/Developer}"
fi
export COPYFILE_DISABLE=1

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
bash "$ROOT_DIR/scripts/build-app.sh"

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --verify|verify)
        open_app
        for _ in {1..20}; do
            if pgrep -x "$APP_NAME" >/dev/null; then
                echo "Verified running process: $APP_NAME"
                exit 0
            fi
            sleep 0.1
        done
        echo "Process did not start: $APP_NAME" >&2
        exit 1
        ;;
    *)
        echo "usage: $0 [release|run|debug|logs|verify]" >&2
        exit 2
        ;;
esac
