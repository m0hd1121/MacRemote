#!/bin/bash
# Builds MacAlwaysOn.app from the Swift package.
#
#   Scripts/build-app.sh               native architecture, ad-hoc signed
#   Scripts/build-app.sh --universal   arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh   real signature + hardened runtime
#
# Output: build/MacAlwaysOn.app
#   Contents/MacOS/MacAlwaysOn                 SwiftUI app
#   Contents/MacOS/alwaysond                   LaunchAgent (user)
#   Contents/Library/Helpers/alwaysonhelper    optional LaunchDaemon (root), copied out by install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
        *) echo "Unknown option: $arg" >&2; exit 64 ;;
    esac
done

echo "==> Building (release)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/MacAlwaysOn.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/Helpers" \
         "$APP/Contents/Library/LaunchAgents" "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Resources"
cp "$BIN/MacAlwaysOn" "$APP/Contents/MacOS/MacAlwaysOn"
cp "$BIN/alwaysond" "$APP/Contents/MacOS/alwaysond"
cp "$BIN/alwaysonhelper" "$APP/Contents/Library/Helpers/alwaysonhelper"
cp Resources/App/Info.plist "$APP/Contents/Info.plist"
cp Resources/LaunchAgents/com.macalwayson.agent.plist "$APP/Contents/Library/LaunchAgents/"
cp Resources/LaunchDaemons/com.macalwayson.helper.plist "$APP/Contents/Library/LaunchDaemons/"

IDENTITY="${SIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi
echo "==> Signing (${IDENTITY/#-/ad-hoc})"
codesign "${SIGN_FLAGS[@]}" --identifier com.macalwayson.helper "$APP/Contents/Library/Helpers/alwaysonhelper"
codesign "${SIGN_FLAGS[@]}" --identifier com.macalwayson.agent "$APP/Contents/MacOS/alwaysond"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"
lipo -info "$APP/Contents/MacOS/alwaysond" || true
