#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-My Swift Dev Cert}"

usage() {
    cat >&2 <<'EOF'
usage: scripts/sign-built-product.sh <product-name> [debug|release]
EOF
    exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
fi

PRODUCT_NAME="$1"
CONFIGURATION="${2:-debug}"

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "Unsupported configuration: $CONFIGURATION" >&2
        usage
        ;;
esac

if ! security find-identity -v -p codesigning | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null; then
    cat >&2 <<EOF
Configured signing identity "$SIGNING_IDENTITY" was not found.

Create or import the certificate first, or rerun with:
  SIGNING_IDENTITY="Your Certificate Name" ./scripts/sign-built-product.sh "$PRODUCT_NAME" "$CONFIGURATION"
EOF
    exit 1
fi

BUILD_ARGS=(build --product "$PRODUCT_NAME")
SHOW_BIN_ARGS=(build --show-bin-path)

if [[ "$CONFIGURATION" == "release" ]]; then
    BUILD_ARGS=(-c release "${BUILD_ARGS[@]}")
    SHOW_BIN_ARGS=(-c release "${SHOW_BIN_ARGS[@]}")
fi

"$ROOT_DIR/scripts/swift-package.sh" "${BUILD_ARGS[@]}"

BIN_DIR="$("$ROOT_DIR/scripts/swift-package.sh" "${SHOW_BIN_ARGS[@]}")"
EXECUTABLE_PATH="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Built product not found at $EXECUTABLE_PATH" >&2
    exit 1
fi

case "$PRODUCT_NAME" in
    Momentum4PlayPauseBlock)
        IDENTIFIER="com.vellut.momentum4playpauseblock.dev"
        ;;
    Momentum4PlayPauseBlockCLI)
        IDENTIFIER="com.vellut.momentum4playpauseblock.cli.dev"
        ;;
    *)
        IDENTIFIER="com.vellut.${PRODUCT_NAME}.dev"
        ;;
esac

codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --identifier "$IDENTIFIER" \
    --timestamp=none \
    "$EXECUTABLE_PATH"

codesign --verify --strict "$EXECUTABLE_PATH"

echo "Built and signed:"
echo "  $EXECUTABLE_PATH"
