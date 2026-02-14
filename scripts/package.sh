#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: $0 <version> (e.g. 0.1.0)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SIGNING_IDENTITY="${CHIRP_SIGNING_IDENTITY:--}"
NOTARIZE_PROFILE="${CHIRP_NOTARIZE_PROFILE:-}"

DIST="$ROOT/dist"
APP="$DIST/Chirp.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"

DMG_NAME="Chirp-v${VERSION}-macOS.dmg"

echo "==> Building Chirp (release)..."
cd "$ROOT"
swift build -c release

BINARY="$(swift build -c release --show-bin-path)/Chirp"
if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY"
    exit 1
fi

echo "==> Creating app bundle..."
rm -rf "$APP"
mkdir -p "$MACOS" "$FRAMEWORKS" "$RESOURCES"

# Copy binary
cp "$BINARY" "$MACOS/Chirp"

# Copy dylibs
cp "$ROOT/Frameworks/lib/libsherpa-onnx-c-api.dylib" "$FRAMEWORKS/"
cp "$ROOT/Frameworks/lib/libonnxruntime.1.23.2.dylib" "$FRAMEWORKS/"
# Recreate the symlink (some code paths may dlopen the unversioned name)
ln -sf libonnxruntime.1.23.2.dylib "$FRAMEWORKS/libonnxruntime.dylib"

# Copy Sparkle.framework from SPM build artifacts
SPARKLE_FRAMEWORK=$(find "$(swift build -c release --show-bin-path)/../../.." -name "Sparkle.framework" -path "*/macos-*" | head -1)
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
    echo "==> Copying Sparkle.framework from $SPARKLE_FRAMEWORK"
    cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/"
else
    echo "Warning: Sparkle.framework not found in build artifacts"
fi

# Copy Info.plist, stamp the version
cp "$ROOT/Sources/Chirp/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"

# Copy icon if it exists
if [[ -f "$ROOT/Sources/Chirp/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Sources/Chirp/Resources/AppIcon.icns" "$RESOURCES/"
fi

# Copy entitlements (needed for signing step)
ENTITLEMENTS="$ROOT/Sources/Chirp/Chirp.entitlements"

echo "==> Fixing rpaths on binary..."
# Remove build-time rpaths (ignore errors if they don't exist)
for rp in $(otool -l "$MACOS/Chirp" | grep -A2 "cmd LC_RPATH" | grep "^\s*path" | awk '{print $2}'); do
    install_name_tool -delete_rpath "$rp" "$MACOS/Chirp" 2>/dev/null || true
done
# Add the app-bundle rpath
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Chirp"

echo "==> Fixing rpaths on sherpa dylib..."
# sherpa needs to find onnxruntime next to itself via @loader_path
# Remove all rpaths except @loader_path, then add it if missing
for rp in $(otool -l "$FRAMEWORKS/libsherpa-onnx-c-api.dylib" | grep -A2 "cmd LC_RPATH" | grep "^\s*path" | awk '{print $2}'); do
    if [[ "$rp" != "@loader_path" ]]; then
        install_name_tool -delete_rpath "$rp" "$FRAMEWORKS/libsherpa-onnx-c-api.dylib" 2>/dev/null || true
    fi
done
install_name_tool -add_rpath "@loader_path" "$FRAMEWORKS/libsherpa-onnx-c-api.dylib" 2>/dev/null || true

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

# Sign Sparkle.framework if present
if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --deep \
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
