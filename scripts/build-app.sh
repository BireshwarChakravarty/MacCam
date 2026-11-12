#!/usr/bin/env bash
# Builds dist/MacCam.app with SwiftPM (no Xcode project needed).
# This build has every feature except the virtual camera, which needs the
# Xcode project + an Apple Developer signing identity (see README).
#
#   ./scripts/build-app.sh            # native architecture
#   UNIVERSAL=1 ./scripts/build-app.sh  # Apple Silicon + Intel (needs full Xcode)
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-com.maccam.app}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARGS+=(--arch arm64 --arch x86_64)
fi

echo "▸ Building (swift build ${ARGS[*]})"
swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

APP="dist/MacCam.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacCam" "$APP/Contents/MacOS/MacCam"

sed -e 's/[$](PRODUCT_BUNDLE_IDENTIFIER)/'"$BUNDLE_ID"'/' \
    -e 's/[$](MARKETING_VERSION)/'"$VERSION"'/' \
    -e 's/[$](CURRENT_PROJECT_VERSION)/'"$BUILD_NUMBER"'/' \
    Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)"
codesign --force --options runtime --entitlements Resources/MacCam-adhoc.entitlements --sign - "$APP"

echo "✓ Built $APP"
echo "  Run it:  open $APP"
