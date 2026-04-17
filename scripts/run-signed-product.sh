#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-signed-product.sh <product-name> [debug|release] [-- <arguments...>]
EOF
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

PRODUCT_NAME="$1"
shift

CONFIGURATION="debug"
if [[ $# -gt 0 && ( "$1" == "debug" || "$1" == "release" ) ]]; then
    CONFIGURATION="$1"
    shift
fi

RUN_ARGS=()
if [[ $# -gt 0 ]]; then
    if [[ "$1" != "--" ]]; then
        usage
    fi
    shift
    RUN_ARGS=("$@")
fi

"$ROOT_DIR/scripts/sign-built-product.sh" "$PRODUCT_NAME" "$CONFIGURATION"

SHOW_BIN_ARGS=(build --show-bin-path)
if [[ "$CONFIGURATION" == "release" ]]; then
    SHOW_BIN_ARGS=(-c release "${SHOW_BIN_ARGS[@]}")
fi

BIN_DIR="$("$ROOT_DIR/scripts/swift-package.sh" "${SHOW_BIN_ARGS[@]}")"
exec "$BIN_DIR/$PRODUCT_NAME" "${RUN_ARGS[@]}"
