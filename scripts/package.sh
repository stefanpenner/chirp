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
    # Zip is the preferred Sparkle update archive (preserves +x; simpler install).
    local zip_name="Chirp-v${version}-macOS.zip"

    restore_sparkle_executables() {
        local root_fw="$1"
        [[ -d "$root_fw" ]] || return 0
        find "$root_fw" -type f \( \
            -name 'Autoupdate' -o -name 'Sparkle' -o -name 'Updater' \
            -o -name 'Installer' -o -name 'Downloader' \
            -o -path '*/MacOS/*' \
        \) -exec chmod a+x {} +
    }

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

    # Bazel zip → unzip drops +x on Sparkle helpers (Autoupdate, Updater, XPCs).
    # launchd then fails with errno 13 and Sparkle shows:
    #   "An error occurred while running the updater... may not have executable permissions"
    if [[ -d "$frameworks/Sparkle.framework" ]]; then
        echo "==> Restoring Sparkle helper execute bits..."
        restore_sparkle_executables "$frameworks/Sparkle.framework"
        local autoupdate="$frameworks/Sparkle.framework/Versions/B/Autoupdate"
        if [[ -f "$autoupdate" && ! -x "$autoupdate" ]]; then
            echo "ERROR: $autoupdate is not executable after chmod"
            ls -la "$autoupdate"
            exit 1
        fi
        if [[ -f "$autoupdate" ]]; then
            echo "    Autoupdate mode: $(stat -f '%Sp' "$autoupdate")"
        fi
    fi

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

    # Sign Sparkle.framework inside-out (Sparkle 2 docs).
    # CRITICAL: --preserve-metadata=entitlements — bare re-sign strips Autoupdate's
    # application-identifier and XPC entitlements, which surfaces as:
    #   "An error occurred while running the updater. Please try again later."
    if [[ -d "$frameworks/Sparkle.framework" ]]; then
        local sparkle_b
        sparkle_b="$frameworks/Sparkle.framework/Versions/B"
        local preserve=(--preserve-metadata=entitlements,flags,runtime)

        # XPC services first (innermost)
        if [[ -d "$sparkle_b/XPCServices" ]]; then
            find "$sparkle_b/XPCServices" -name '*.xpc' -type d | while read -r xpc; do
                codesign --force --sign "$signing_identity" --timestamp --options runtime \
                    "${preserve[@]}" "$xpc"
            done
        fi
        # Autoupdate binary (not under MacOS/) — must keep app-id entitlement
        if [[ -f "$sparkle_b/Autoupdate" ]]; then
            codesign --force --sign "$signing_identity" --timestamp --options runtime \
                "${preserve[@]}" "$sparkle_b/Autoupdate"
        fi
        # Updater.app
        if [[ -d "$sparkle_b/Updater.app" ]]; then
            codesign --force --sign "$signing_identity" --timestamp --options runtime \
                "${preserve[@]}" "$sparkle_b/Updater.app"
        fi
        # Framework binary + outer framework bundle
        if [[ -f "$sparkle_b/Sparkle" ]]; then
            codesign --force --sign "$signing_identity" --timestamp --options runtime \
                "${preserve[@]}" "$sparkle_b/Sparkle"
        fi
        codesign --force --sign "$signing_identity" --timestamp --options runtime \
            "${preserve[@]}" "$frameworks/Sparkle.framework"

        # Sanity: Autoupdate must stay executable + keep application-identifier
        if [[ -f "$sparkle_b/Autoupdate" ]]; then
            if [[ ! -x "$sparkle_b/Autoupdate" ]]; then
                echo "ERROR: Sparkle Autoupdate is not executable after signing"
                ls -la "$sparkle_b/Autoupdate"
                exit 1
            fi
            local ents
            ents="$(codesign -d --entitlements :- "$sparkle_b/Autoupdate" 2>/dev/null || true)"
            if [[ "$ents" != *"application-identifier"* && "$signing_identity" != "-" ]]; then
                echo "ERROR: Sparkle Autoupdate lost entitlements after re-sign (updater will fail)"
                echo "$ents"
                exit 1
            fi
            echo "    Sparkle Autoupdate: executable + entitlements OK"
        fi
    fi

    # Sign the app bundle with entitlements and hardened runtime
    codesign --force --sign "$signing_identity" --timestamp \
        --options runtime \
        --entitlements "$entitlements" \
        "$app"

    echo "==> Verifying signature..."
    codesign --verify --deep --strict "$app"
    echo "    Signature OK"

    # --- Sparkle update archive (zip) — preferred by Sparkle 2 ---
    echo "==> Creating update zip (Sparkle)..."
    rm -f "$dist/$zip_name"
    # ditto preserves execute bits; plain zip often does not.
    (cd "$dist" && ditto -c -k --keepParent "Chirp.app" "$zip_name")
    local zip_check
    zip_check="$(mktemp -d /tmp/chirp-zipchk-XXXXXX)"
    unzip -q -j "$dist/$zip_name" \
        "Chirp.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
        -d "$zip_check" || true
    if [[ ! -x "$zip_check/Autoupdate" ]]; then
        echo "    Autoupdate not +x after unzip; re-chmod app and re-zip"
        restore_sparkle_executables "$frameworks/Sparkle.framework"
        chmod a+x "$frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
        rm -f "$dist/$zip_name"
        (cd "$dist" && ditto -c -k --keepParent "Chirp.app" "$zip_name")
        rm -rf "$zip_check"
        zip_check="$(mktemp -d /tmp/chirp-zipchk-XXXXXX)"
        unzip -q -j "$dist/$zip_name" \
            "Chirp.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
            -d "$zip_check"
        if [[ ! -x "$zip_check/Autoupdate" ]]; then
            echo "ERROR: Autoupdate still not executable inside update zip"
            ls -la "$zip_check" || true
            exit 1
        fi
    fi
    rm -rf "$zip_check"
    echo "    ZIP Autoupdate is executable ($(stat -f%z "$dist/$zip_name") bytes)"

    # --- DMG for manual / Homebrew install ---
    echo "==> Creating DMG..."
    rm -f "$dist/$dmg_name"

    local dmg_stage
    dmg_stage="$(mktemp -d /tmp/chirp-dmg-XXXXXX)"
    ditto "$app" "$dmg_stage/Chirp.app"
    restore_sparkle_executables "$dmg_stage/Chirp.app/Contents/Frameworks/Sparkle.framework"
    ln -s /Applications "$dmg_stage/Applications"

    local dmg_tmp
    dmg_tmp="$(mktemp /tmp/Chirp-XXXXXX.dmg)"
    rm -f "$dmg_tmp"
    hdiutil create -volname "Chirp" \
        -srcfolder "$dmg_stage" \
        -ov -format UDZO \
        -imagekey zlib-level=9 \
        "$dmg_tmp"
    mv "$dmg_tmp" "$dist/$dmg_name"

    local mnt
    mnt="$(mktemp -d /tmp/chirp-mnt-XXXXXX)"
    hdiutil attach "$dist/$dmg_name" -readonly -nobrowse -mountpoint "$mnt" >/dev/null
    if [[ ! -x "$mnt/Chirp.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" ]]; then
        echo "ERROR: Autoupdate not executable inside DMG"
        ls -la "$mnt/Chirp.app/Contents/Frameworks/Sparkle.framework/Versions/B/" || true
        hdiutil detach "$mnt" >/dev/null 2>&1 || true
        exit 1
    fi
    echo "    DMG Autoupdate is executable"
    hdiutil detach "$mnt" >/dev/null
    rmdir "$mnt" 2>/dev/null || true
    rm -rf "$dmg_stage"

    # Notarize if configured (zip for Sparkle + DMG for humans)
    if [[ -n "$notarize_profile" ]]; then
        echo "==> Notarizing update zip..."
        local notarize_output
        notarize_output=$(xcrun notarytool submit "$dist/$zip_name" \
            --keychain-profile "$notarize_profile" \
            --wait 2>&1)
        echo "$notarize_output"
        if echo "$notarize_output" | grep -q "status: Invalid"; then
            local submission_id
            submission_id=$(echo "$notarize_output" | grep "id:" | head -1 | awk '{print $2}')
            echo "ERROR: Zip notarization failed."
            xcrun notarytool log "$submission_id" \
                --keychain-profile "$notarize_profile" 2>&1 || true
            exit 1
        fi

        echo "==> Notarizing DMG..."
        notarize_output=$(xcrun notarytool submit "$dist/$dmg_name" \
            --keychain-profile "$notarize_profile" \
            --wait 2>&1)
        echo "$notarize_output"
        if echo "$notarize_output" | grep -q "status: Invalid"; then
            local submission_id
            submission_id=$(echo "$notarize_output" | grep "id:" | head -1 | awk '{print $2}')
            echo "ERROR: DMG notarization failed."
            xcrun notarytool log "$submission_id" \
                --keychain-profile "$notarize_profile" 2>&1 || true
            exit 1
        fi

        echo "==> Stapling notarization ticket on DMG..."
        xcrun stapler staple "$dist/$dmg_name"
        # Zip cannot be stapled; Gatekeeper fetches ticket online.
    fi

    echo ""
    echo "Done! Outputs:"
    echo "  App: $app"
    echo "  ZIP (Sparkle): $dist/$zip_name"
    echo "  DMG (manual):  $dist/$dmg_name"
    echo ""
    echo "Verify with:"
    echo "  otool -l $macos/Chirp | grep -A2 LC_RPATH"
    echo "  otool -L $macos/Chirp"
    echo "  open $app"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
