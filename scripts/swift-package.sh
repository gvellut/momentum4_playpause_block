#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
CLANG_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
SWIFTPM_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"

mkdir -p "$MODULE_CACHE_PATH" "$CLANG_CACHE_PATH" "$SWIFTPM_CACHE_PATH"

SDKROOT_CANDIDATE=""
for candidate in \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk" \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk"
do
    if [[ -d "$candidate" ]]; then
        SDKROOT_CANDIDATE="$candidate"
        break
    fi
done

if [[ -z "$SDKROOT_CANDIDATE" ]]; then
    SDKROOT_CANDIDATE="$(xcrun --sdk macosx --show-sdk-path)"
fi

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <swift-subcommand> [arguments...]" >&2
    exit 1
fi

subcommand="$1"
shift

swift_base_command=(
    env
    "SDKROOT=$SDKROOT_CANDIDATE"
    "CLANG_MODULE_CACHE_PATH=$CLANG_CACHE_PATH"
    swift
    "$subcommand"
    --cache-path "$SWIFTPM_CACHE_PATH"
    -Xswiftc -module-cache-path
    -Xswiftc "$MODULE_CACHE_PATH"
    -Xcc "-fmodules-cache-path=$CLANG_CACHE_PATH"
)

exec "${swift_base_command[@]}" "$@"
