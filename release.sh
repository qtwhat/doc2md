#!/bin/bash
# Release packaging script for Doc2Md.
#
# What this does:
#   1. Clean release build
#   2. Code-sign with Developer ID (if available)
#   3. Package into a compressed .dmg
#   4. Compute SHA-256 checksum
#   5. (Optional) Notarize via notarytool when credentials are set
#   6. (Optional) Staple notarization ticket to the .dmg
#
# Run modes:
#   ./release.sh              # build + dmg, no signing/notarization
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./release.sh
#                             # build + sign + dmg
#   NOTARY_PROFILE=mydev DEVELOPER_ID="..." ./release.sh
#                             # build + sign + dmg + notarize + staple
#
# Prerequisites for notarization (one-time):
#   1. Apple Developer Program membership ($99/year)
#   2. Developer ID Application certificate in Keychain
#   3. Create an app-specific password at https://appleid.apple.com
#   4. Store credentials in keychain:
#      xcrun notarytool store-credentials mydev \
#          --apple-id you@example.com \
#          --team-id YOUR_TEAM_ID \
#          --password app-specific-password
#   Then set NOTARY_PROFILE=mydev when invoking this script.

set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep -E '^- \*\*v[0-9]' CHANGELOG.md | head -1 | sed 's/.*v\([0-9.]*\).*/\1/')
APP_NAME="Doc2Md"
BUILD_DIR="build/release"
DMG_DIR="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

echo "=== Release: ${APP_NAME} v${VERSION} ==="

# 1. Clean build
echo "[1/6] Building Release configuration"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
xcodebuild \
    -project Doc2Md.xcodeproj \
    -scheme Doc2Md \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    CONFIGURATION_BUILD_DIR="$PWD/$BUILD_DIR/products" \
    clean build \
    > "$BUILD_DIR/build.log" 2>&1 \
    || { echo "Build failed. Last 40 lines of build.log:"; tail -40 "$BUILD_DIR/build.log"; exit 1; }

APP_BUILT="$BUILD_DIR/products/${APP_NAME}.app"
if [ ! -d "$APP_BUILT" ]; then
    echo "Error: ${APP_BUILT} not found after build."
    exit 1
fi
echo "    Built: $APP_BUILT"

# 2. Sign (if cert available)
if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "[2/6] Code-signing with: $DEVELOPER_ID"
    codesign --force --deep \
        --options runtime \
        --timestamp \
        --sign "$DEVELOPER_ID" \
        "$APP_BUILT"
    codesign --verify --deep --strict --verbose=2 "$APP_BUILT"
else
    echo "[2/6] Skipping codesign (no DEVELOPER_ID set)"
fi

# 3. Build .dmg
echo "[3/6] Packaging .dmg"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_BUILT" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    > "$BUILD_DIR/hdiutil.log" 2>&1
echo "    Created: $DMG_PATH"

# 4. Checksum
echo "[4/6] Computing SHA-256"
shasum -a 256 "$DMG_PATH" | tee "${DMG_PATH}.sha256"

# 5. Notarize (optional)
if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${DEVELOPER_ID:-}" ]; then
        echo "Error: NOTARY_PROFILE is set but the .app was not signed. Set DEVELOPER_ID."
        exit 1
    fi
    echo "[5/6] Submitting for notarization (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "[6/6] Stapling notarization ticket"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    echo "[5/6] Skipping notarization (no NOTARY_PROFILE set)"
    echo "[6/6] Skipping staple (no notarization)"
fi

echo ""
echo "=== Done ==="
echo "Distribute: $DMG_PATH"
ls -lh "$DMG_PATH"
