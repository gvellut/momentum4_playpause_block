#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Momentum4PlayPauseBlock"
BUNDLE_IDENTIFIER="com.vellut.momentum4playpauseblock"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-My Swift Dev Cert}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
CLANG_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
SWIFTPM_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"
CLT_SDK_DIR="/Library/Developer/CommandLineTools/SDKs"
PREFERRED_SDK_VERSION="${PREFERRED_SDK_VERSION:-26.2}"

resolve_sdkroot() {
    if [[ -n "${SDKROOT:-}" && -d "$SDKROOT" ]]; then
        printf '%s\n' "$SDKROOT"
        return
    fi

    if [[ -d "$CLT_SDK_DIR" ]]; then
        local preferred_sdk="$CLT_SDK_DIR/MacOSX$PREFERRED_SDK_VERSION.sdk"
        if [[ -d "$preferred_sdk" ]]; then
            printf '%s\n' "$preferred_sdk"
            return
        fi

        local preferred_major="${PREFERRED_SDK_VERSION%%.*}"
        local preferred_major_candidate=""
        local best_candidate=""

        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if [[ -z "$preferred_major_candidate" && "$(basename "$candidate")" == MacOSX"$preferred_major"*\.sdk ]]; then
                preferred_major_candidate="$candidate"
            fi
            best_candidate="$candidate"
        done < <(
            find "$CLT_SDK_DIR" -maxdepth 1 -type d -name 'MacOSX*.sdk' -print \
                | sort -V -r
        )

        if [[ -n "$preferred_major_candidate" ]]; then
            printf '%s\n' "$preferred_major_candidate"
            return
        fi

        if [[ -n "$best_candidate" ]]; then
            printf '%s\n' "$best_candidate"
            return
        fi
    fi

    xcrun --sdk macosx --show-sdk-path
}

swift_build() {
    env \
        "SDKROOT=$SDKROOT_CANDIDATE" \
        "CLANG_MODULE_CACHE_PATH=$CLANG_CACHE_PATH" \
        swift \
        build \
        --cache-path "$SWIFTPM_CACHE_PATH" \
        -Xswiftc -module-cache-path \
        -Xswiftc "$MODULE_CACHE_PATH" \
        -Xcc "-fmodules-cache-path=$CLANG_CACHE_PATH" \
        "$@"
}

mkdir -p "$MODULE_CACHE_PATH" "$CLANG_CACHE_PATH" "$SWIFTPM_CACHE_PATH" "$DIST_DIR"

SDKROOT_CANDIDATE="$(resolve_sdkroot)"

swift_build -c release --product "$APP_NAME"

BIN_DIR="$(swift_build -c release --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/$APP_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Built product not found at $EXECUTABLE_PATH" >&2
    exit 1
fi

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

if ! codesign_output="$(
    codesign \
        --force \
        --options runtime \
        --sign "$SIGNING_IDENTITY" \
        --timestamp=none \
        "$APP_BUNDLE" \
        2>&1
)"; then
    printf '%s\n' "$codesign_output" >&2
    cat >&2 <<EOF

Failed to sign "$APP_BUNDLE" with identity "$SIGNING_IDENTITY".

If the certificate exists in Keychain Access but is still rejected, check that the
matching private key is present and usable for code signing:
  security find-identity -v -p codesigning

If the certificate has a different common name, rerun with:
  SIGNING_IDENTITY="Your Certificate Name" ./scripts/build-app.sh
EOF
    exit 1
fi

codesign --verify --deep --strict "$APP_BUNDLE"

echo "Built signed app bundle at:"
echo "  $APP_BUNDLE"
