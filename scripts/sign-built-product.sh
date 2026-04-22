#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-My Swift Dev Cert}"
MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
CLANG_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
SWIFTPM_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"
CLT_SDK_DIR="/Library/Developer/CommandLineTools/SDKs"
PREFERRED_SDK_VERSION="${PREFERRED_SDK_VERSION:-26.2}"
SDKROOT_CANDIDATE="${SDKROOT_CANDIDATE:-}"
EXECUTABLE_PATH="${EXECUTABLE_PATH:-}"

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

ensure_swift_build_context() {
    mkdir -p "$MODULE_CACHE_PATH" "$CLANG_CACHE_PATH" "$SWIFTPM_CACHE_PATH"

    if [[ -z "$SDKROOT_CANDIDATE" ]]; then
        SDKROOT_CANDIDATE="$(resolve_sdkroot)"
    fi
}

swift_build() {
    ensure_swift_build_context

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

product_identifier() {
    local product_name="$1"

    case "$product_name" in
        Momentum4PlayPauseBlock)
            printf '%s\n' "com.vellut.momentum4playpauseblock.dev"
            ;;
        Momentum4PlayPauseBlockCLI)
            printf '%s\n' "com.vellut.momentum4playpauseblock.cli.dev"
            ;;
        Momentum4PlayPauseBlockDiagCLI)
            printf '%s\n' "com.vellut.momentum4playpauseblock.diag.dev"
            ;;
        *)
            printf '%s\n' "com.vellut.${product_name}.dev"
            ;;
    esac
}

sign_built_product() {
    local product_name="$1"
    local configuration="${2:-debug}"
    local -a build_args=(--product "$product_name")
    local -a bin_path_args=(--show-bin-path)
    local identifier=""
    local codesign_output=""
    local bin_dir=""

    case "$configuration" in
        debug|release) ;;
        *)
            echo "Unsupported configuration: $configuration" >&2
            return 1
            ;;
    esac

    if [[ "$configuration" == "release" ]]; then
        build_args=(-c release "${build_args[@]}")
        bin_path_args=(-c release "${bin_path_args[@]}")
    fi

    swift_build "${build_args[@]}"

    bin_dir="$(swift_build "${bin_path_args[@]}")"
    EXECUTABLE_PATH="$bin_dir/$product_name"

    if [[ ! -x "$EXECUTABLE_PATH" ]]; then
        echo "Built product not found at $EXECUTABLE_PATH" >&2
        return 1
    fi

    identifier="$(product_identifier "$product_name")"

    if ! codesign_output="$(
        codesign \
            --force \
            --sign "$SIGNING_IDENTITY" \
            --identifier "$identifier" \
            --timestamp=none \
            "$EXECUTABLE_PATH" \
            2>&1
    )"; then
        printf '%s\n' "$codesign_output" >&2
        cat >&2 <<EOF

Failed to sign "$EXECUTABLE_PATH" with identity "$SIGNING_IDENTITY".

If the certificate exists in Keychain Access but is still rejected, check that the
matching private key is present and usable for code signing:
  security find-identity -v -p codesigning

If the certificate has a different common name, rerun with:
  SIGNING_IDENTITY="Your Certificate Name" ./scripts/sign-built-product.sh "$product_name" "$configuration"
EOF
        return 1
    fi

    codesign --verify --strict "$EXECUTABLE_PATH"
}

usage() {
    cat >&2 <<'EOF'
usage: scripts/sign-built-product.sh <product-name> [debug|release]
EOF
}

main() {
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        usage
        exit 1
    fi

    sign_built_product "$1" "${2:-debug}"

    echo "Built and signed:"
    echo "  $EXECUTABLE_PATH"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
