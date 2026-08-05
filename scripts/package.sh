#!/usr/bin/env bash
set -euo pipefail

# Resolve project root from script location or Bazel workspace.
resolve_root() {
    if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
        echo "$BUILD_WORKSPACE_DIRECTORY"
    else
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        cd "$script_dir/.." && pwd
    fi
}

# Monotonic integer build from semver X.Y.Z → X*1_000_000 + Y*1000 + Z.
# Example: 0.3.26 → 3026. Does not depend on git tags (CI shallow clones break tag counts).
# Usage: compute_build_number <version> [explicit_number]
compute_build_number() {
    local version="$1"
    local explicit="${2:-}"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi
    local major minor patch
    IFS=. read -r major minor patch <<<"$version"
    major=${major:-0}
    minor=${minor:-0}
    patch=${patch:-0}
    # strip non-digits (e.g. 0.3.26-beta)
    major=${major//[^0-9]/}
    minor=${minor//[^0-9]/}
    patch=${patch//[^0-9]/}
    echo $(( 10#${major:-0} * 1000000 + 10#${minor:-0} * 1000 + 10#${patch:-0} ))
}

# Stamp CFBundleShortVersionString and CFBundleVersion into an Info.plist.
# Usage: stamp_version <plist_path> <version> <build_number>
stamp_version() {
    local plist="$1" version="$2" build_number="$3"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
}

main() {
    local version="${1:?Usage: $0 <version> [build-number] (e.g. 0.1.0)}"
    local build_number_arg="${2:-}"

    local root
    root="$(resolve_root)"

    local build_number
    build_number="$(compute_build_number "$version" "$build_number_arg")"

    # Ensure dependencies are present
    "$root/scripts/setup.sh"

    local signing_identity="${CHIRP_SIGNING_IDENTITY:--}"
    local notarize_profile="${CHIRP_NOTARIZE_PROFILE:-}"

    local dist="$root/dist"
    local app="$dist/Chirp.app"
    local contents="$app/Contents"
    local macos="$contents/MacOS"
    local frameworks="$contents/Frameworks"
    local dmg_name="Chirp-v${version}-macOS.dmg"

    echo "==> Building Chirp with Bazel..."
    cd "$root"
    bazel build //:Chirp

    echo "==> Extracting app bundle..."
    rm -rf "$app"
    mkdir -p "$dist"
    unzip -o bazel-bin/Chirp.zip -d "$dist" > /dev/null

    stamp_version "$contents/Info.plist" "$version" "$build_number"
    echo "    Version: $version (build $build_number)"

    # Copy entitlements (needed for signing step)
    local entitlements="$root/Sources/Chirp/Chirp.entitlements"

    echo "==> Cleaning rpaths on binary..."
    # Remove build-time toolchain rpaths, keep only @executable_path/../Frameworks
    for rp in $(otool -l "$macos/Chirp" | grep -A2 "cmd LC_RPATH" | grep "^\s*path" | awk '{print $2}'); do
        if [[ "$rp" != "@executable_path/../Frameworks" ]]; then
            install_name_tool -delete_rpath "$rp" "$macos/Chirp" 2>/dev/null || true
        fi
    done

    echo "==> Code signing..."
    if [[ "$signing_identity" == "-" ]]; then
        echo "    (ad-hoc signing)"
    else
        echo "    Identity: $signing_identity"
    fi

    # Sign dylibs first (innermost out)
    codesign --force --sign "$signing_identity" --timestamp \
        "$frameworks/libonnxruntime.1.23.2.dylib"
    codesign --force --sign "$signing_identity" --timestamp \
        "$frameworks/libsherpa-onnx-c-api.dylib"

    # Sign Sparkle.framework inside-out. Autoupdate + XPC live outside */MacOS/*
    # — a path-only find misses them and leaves helpers with broken team linkage
    # for in-app updates ("An error occurred while running the updater").
    if [[ -d "$frameworks/Sparkle.framework" ]]; then
        local sparkle_b
        sparkle_b="$frameworks/Sparkle.framework/Versions/B"
        # XPC services first
        if [[ -d "$sparkle_b/XPCServices" ]]; then
            find "$sparkle_b/XPCServices" -name '*.xpc' -type d | while read -r xpc; do
                codesign --force --sign "$signing_identity" --timestamp --options runtime "$xpc"
            done
        fi
        # Autoupdate binary (not under MacOS/)
        if [[ -f "$sparkle_b/Autoupdate" ]]; then
            codesign --force --sign "$signing_identity" --timestamp --options runtime \
                "$sparkle_b/Autoupdate"
        fi
        # Updater.app
        if [[ -d "$sparkle_b/Updater.app" ]]; then
            codesign --force --sign "$signing_identity" --timestamp --options runtime \
                "$sparkle_b/Updater.app"
        fi
        # Framework binary + bundle
        if [[ -f "$sparkle_b/Sparkle" ]]; then
            codesign --force --sign "$signing_identity" --timestamp --options runtime \
                "$sparkle_b/Sparkle"
        fi
        codesign --force --sign "$signing_identity" --timestamp --options runtime \
            "$frameworks/Sparkle.framework"
    fi

    # Sign the app bundle with entitlements and hardened runtime
    codesign --force --sign "$signing_identity" --timestamp \
        --options runtime \
        --entitlements "$entitlements" \
        "$app"

    echo "==> Verifying signature..."
    codesign --verify --deep --strict "$app"
    echo "    Signature OK"

    echo "==> Creating DMG..."
    rm -f "$dist/$dmg_name"

    # Create a temporary directory for DMG contents
    local dmg_stage="$dist/dmg-stage"
    rm -rf "$dmg_stage"
    mkdir -p "$dmg_stage"
    cp -R "$app" "$dmg_stage/"
    ln -s /Applications "$dmg_stage/Applications"

    hdiutil create -volname "Chirp" \
        -srcfolder "$dmg_stage" \
        -ov -format UDZO \
        "$dist/$dmg_name"

    rm -rf "$dmg_stage"

    # Notarize if configured
    if [[ -n "$notarize_profile" ]]; then
        echo "==> Notarizing DMG..."
        local notarize_output
        notarize_output=$(xcrun notarytool submit "$dist/$dmg_name" \
            --keychain-profile "$notarize_profile" \
            --wait 2>&1)
        echo "$notarize_output"

        if echo "$notarize_output" | grep -q "status: Invalid"; then
            local submission_id
            submission_id=$(echo "$notarize_output" | grep "id:" | head -1 | awk '{print $2}')
            echo "ERROR: Notarization failed. Fetching details..."
            xcrun notarytool log "$submission_id" \
                --keychain-profile "$notarize_profile" 2>&1 || true
            exit 1
        fi

        echo "==> Stapling notarization ticket..."
        xcrun stapler staple "$dist/$dmg_name"
    fi

    echo ""
    echo "Done! Outputs:"
    echo "  App: $app"
    echo "  DMG: $dist/$dmg_name"
    echo ""
    echo "Verify with:"
    echo "  otool -l $macos/Chirp | grep -A2 LC_RPATH"
    echo "  otool -L $macos/Chirp"
    echo "  open $app"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
