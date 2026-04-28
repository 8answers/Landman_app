#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must be run on macOS."
  exit 1
fi

VERSION_RAW="${1:-${APP_VERSION:-}}"
VERSION="${VERSION_RAW#v}"
VERSION="${VERSION#V}"

BUILD_ARGS=(macos --release)
if [[ -n "$VERSION" ]]; then
  BUILD_ARGS+=(--dart-define=APP_RELEASE_VERSION="v$VERSION")
fi

echo "Building macOS release..."
flutter build "${BUILD_ARGS[@]}"

RELEASE_DIR="$ROOT_DIR/build/macos/Build/Products/Release"
DIST_DIR="$ROOT_DIR/build/macos/dist"
PKG_ROOT="$ROOT_DIR/build/macos/installer_payload"

mkdir -p "$DIST_DIR"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT"

mapfile -t APP_CANDIDATES < <(find "$RELEASE_DIR" -maxdepth 1 -type d -name "*.app" | sort)
if [[ ${#APP_CANDIDATES[@]} -eq 0 ]]; then
  echo "No .app bundle found in $RELEASE_DIR"
  exit 1
fi

APP_BUNDLE="${APP_CANDIDATES[0]}"
APP_NAME="$(basename "$APP_BUNDLE" .app)"

echo "Using app bundle: $APP_BUNDLE"
cp -R "$APP_BUNDLE" "$PKG_ROOT/"
ln -s /Applications "$PKG_ROOT/Applications"

if [[ -n "$VERSION" ]]; then
  BASE_NAME="${APP_NAME}_v${VERSION}-macos"
else
  BASE_NAME="${APP_NAME}-macos"
fi

ZIP_PATH="$DIST_DIR/${BASE_NAME}.zip"
DMG_PATH="$DIST_DIR/${BASE_NAME}.dmg"

echo "Creating ZIP: $ZIP_PATH"
rm -f "$ZIP_PATH"
(
  cd "$RELEASE_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$(basename "$APP_BUNDLE")" "$ZIP_PATH"
)

echo "Creating DMG with Applications shortcut: $DMG_PATH"
rm -f "$DMG_PATH"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --overwrite \
    --volname "${APP_NAME} Installer" \
    --window-size 700 420 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 190 190 \
    --app-drop-link 510 190 \
    "$DMG_PATH" \
    "$PKG_ROOT"
else
  hdiutil create \
    -volname "${APP_NAME} Installer" \
    -srcfolder "$PKG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

echo "Done."
echo "DMG: $DMG_PATH"
echo "ZIP: $ZIP_PATH"
