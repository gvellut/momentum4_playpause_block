#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
CLANG_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
SWIFTPM_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"
CLT_SDK_DIR="/Library/Developer/CommandLineTools/SDKs"

mkdir -p "$MODULE_CACHE_PATH" "$CLANG_CACHE_PATH" "$SWIFTPM_CACHE_PATH"

resolve_sdkroot() {
    if [[ -n "${SDKROOT:-}" && -d "$SDKROOT" ]]; then
        printf '%s\n' "$SDKROOT"
        return
    fi

    if [[ -d "$CLT_SDK_DIR" ]]; then
        local best_candidate=""

        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            best_candidate="$candidate"
            break
        done < <(
            find "$CLT_SDK_DIR" -maxdepth 1 -type d -name 'MacOSX*.sdk' -print \
                | sort -V -r
        )

        if [[ -n "$best_candidate" ]]; then
            printf '%s\n' "$best_candidate"
            return
        fi
    fi

    xcrun --sdk macosx --show-sdk-path
}

SDKROOT_CANDIDATE="$(resolve_sdkroot)"

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
