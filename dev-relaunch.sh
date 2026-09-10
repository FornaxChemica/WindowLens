#!/bin/bash
# Build (xcodebuild) + install to /Applications + launch.
# Usage:
#   ./dev-relaunch.sh              # build Debug, sync, launch
#   ./dev-relaunch.sh --skip-build # relaunch last build only
#   SKIP_BUILD=1 ./dev-relaunch.sh

set -euo pipefail

APP_NAME="WindowLens"
LEGACY_APP_NAME="BetterTabbing"
INSTALL_APP="/Applications/WindowLens.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="${PROJECT:-WindowLens.xcodeproj}"
SCHEME="${SCHEME:-WindowLens}"
CONFIGURATION="${CONFIGURATION:-Debug}"
# Local derived data keeps the product path stable (no hunting Xcode's global DerivedData).
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$SCRIPT_DIR/.build/DerivedData}"
DERIVED_APP="${DERIVED_APP:-$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/${APP_NAME}.app}"

SKIP_BUILD="${SKIP_BUILD:-0}"
for arg in "$@"; do
    case "$arg" in
        --skip-build|-n) SKIP_BUILD=1 ;;
        --help|-h)
            echo "Usage: ./dev-relaunch.sh [--skip-build]"
            echo "  Builds ${SCHEME} (${CONFIGURATION}) with xcodebuild, syncs to ${INSTALL_APP}, launches."
            echo "  --skip-build  Skip xcodebuild; sync/launch existing product only."
            exit 0
            ;;
    esac
done

is_runnable_app() {
    local app_path="$1"
    local executable_name=""

    [ -d "$app_path" ] || return 1
    [ -d "$app_path/Contents/MacOS" ] || return 1

    if [ -f "$app_path/Contents/Info.plist" ]; then
        executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
    fi

    if [ -n "$executable_name" ] && [ -x "$app_path/Contents/MacOS/$executable_name" ]; then
        return 0
    fi

    find "$app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 -print -quit 2>/dev/null | grep -q .
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Killing existing app..."
killall "$APP_NAME" 2>/dev/null || true
killall "$LEGACY_APP_NAME" 2>/dev/null || true

if [ "$SKIP_BUILD" != "1" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Building ${SCHEME} (${CONFIGURATION})..."
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        build
    echo "Build succeeded."
else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Skipping build (--skip-build)."
fi

if ! is_runnable_app "$DERIVED_APP"; then
    echo "Could not find a runnable app at:"
    echo "  $DERIVED_APP"
    echo "Run without --skip-build, or set DERIVED_APP=/path/to/${APP_NAME}.app."
    exit 1
fi

echo "Using build: $DERIVED_APP"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Syncing build to /Applications..."
mkdir -p "$(dirname "$INSTALL_APP")"
rsync -a --delete "$DERIVED_APP/" "$INSTALL_APP/"

if ! is_runnable_app "$INSTALL_APP"; then
    echo "Installed app is missing an executable: $INSTALL_APP"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Launching installed app..."
open "$INSTALL_APP"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done."
