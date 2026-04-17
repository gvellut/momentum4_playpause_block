#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Momentum4PlayPauseBlock"
BUNDLE_IDENTIFIER="com.guilhem.momentum4playpauseblock"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-My Swift Dev Cert}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

if ! security find-identity -v -p codesigning | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null; then
    cat >&2 <<EOF
Configured signing identity "$SIGNING_IDENTITY" was not found.

Create or import the certificate first, or rerun with:
  SIGNING_IDENTITY="Your Certificate Name" ./scripts/build-app.sh
EOF
    exit 1
fi

"$ROOT_DIR/scripts/swift-package.sh" build -c release --product "$APP_NAME"

BIN_DIR="$("$ROOT_DIR/scripts/swift-package.sh" build -c release --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/$APP_NAME"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign \
    --force \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --timestamp=none \
    "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"

echo "Built signed app bundle at:"
echo "  $APP_BUNDLE"
