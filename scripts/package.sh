#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: $0 <version> (e.g. 0.1.0)}"

# Support both direct invocation and `bazel run //:package -- <version>`
if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    ROOT="$BUILD_WORKSPACE_DIRECTORY"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Ensure dependencies are present
"$ROOT/scripts/setup.sh"

SIGNING_IDENTITY="${CHIRP_SIGNING_IDENTITY:--}"
NOTARIZE_PROFILE="${CHIRP_NOTARIZE_PROFILE:-}"

DIST="$ROOT/dist"
APP="$DIST/Chirp.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"

DMG_NAME="Chirp-v${VERSION}-macOS.dmg"

echo "==> Building Chirp with Bazel..."
cd "$ROOT"
bazel build //:Chirp

echo "==> Extracting app bundle..."
rm -rf "$APP"
mkdir -p "$DIST"
unzip -o bazel-bin/Chirp.zip -d "$DIST" > /dev/null

# Stamp version into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"

# Copy entitlements (needed for signing step)
ENTITLEMENTS="$ROOT/Sources/Chirp/Chirp.entitlements"

echo "==> Cleaning rpaths on binary..."
# Remove build-time toolchain rpaths, keep only @executable_path/../Frameworks
for rp in $(otool -l "$MACOS/Chirp" | grep -A2 "cmd LC_RPATH" | grep "^\s*path" | awk '{print $2}'); do
    if [[ "$rp" != "@executable_path/../Frameworks" ]]; then
        install_name_tool -delete_rpath "$rp" "$MACOS/Chirp" 2>/dev/null || true
    fi
done

echo "==> Code signing..."
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "    (ad-hoc signing)"
else
    echo "    Identity: $SIGNING_IDENTITY"
fi

# Sign dylibs first (innermost out)
codesign --force --sign "$SIGNING_IDENTITY" --timestamp \
    "$FRAMEWORKS/libonnxruntime.1.23.2.dylib"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp \
    "$FRAMEWORKS/libsherpa-onnx-c-api.dylib"

# Sign Sparkle.framework (each executable needs hardened runtime)
if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
    find "$FRAMEWORKS/Sparkle.framework" -type f -perm +111 -path '*/MacOS/*' | while read -r exe; do
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$exe"
    done
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime --deep \
        "$FRAMEWORKS/Sparkle.framework"
fi

# Sign the app bundle with entitlements and hardened runtime
codesign --force --sign "$SIGNING_IDENTITY" --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

echo "==> Verifying signature..."
codesign --verify --deep --strict "$APP"
echo "    Signature OK"

echo "==> Creating DMG..."
rm -f "$DIST/$DMG_NAME"

# Create a temporary directory for DMG contents
DMG_STAGE="$DIST/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create -volname "Chirp" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DIST/$DMG_NAME"

rm -rf "$DMG_STAGE"

# Notarize if configured
if [[ -n "$NOTARIZE_PROFILE" ]]; then
    echo "==> Notarizing DMG..."
    xcrun notarytool submit "$DIST/$DMG_NAME" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$DIST/$DMG_NAME"
fi

echo ""
echo "Done! Outputs:"
echo "  App: $APP"
echo "  DMG: $DIST/$DMG_NAME"
echo ""
echo "Verify with:"
echo "  otool -l $MACOS/Chirp | grep -A2 LC_RPATH"
echo "  otool -L $MACOS/Chirp"
echo "  open $APP"
