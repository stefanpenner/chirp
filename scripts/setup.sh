#!/bin/bash
set -euo pipefail

# Support both direct invocation and `bazel run //:setup`
if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    ROOT="$BUILD_WORKSPACE_DIRECTORY"
else
    cd "$(dirname "$0")/.."
    ROOT="$(pwd)"
fi

SHERPA_VERSION="v1.12.24"
ONNXRUNTIME_VERSION="1.23.2"
TDT_MODEL_NAME="sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"

echo "=== Chirp Setup ==="
echo ""

# --- Download sherpa-onnx shared libraries ---
if [ ! -f "$ROOT/Frameworks/lib/libsherpa-onnx-c-api.dylib" ]; then
    echo "Downloading sherpa-onnx shared libraries (${SHERPA_VERSION})..."
    mkdir -p "$ROOT/Frameworks/lib"
    SHARED_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/sherpa-onnx-${SHERPA_VERSION}-onnxruntime-${ONNXRUNTIME_VERSION}-osx-universal2-shared.tar.bz2"
    curl -L "$SHARED_URL" -o /tmp/sherpa-onnx-shared.tar.bz2
    echo "Extracting..."
    tar xjf /tmp/sherpa-onnx-shared.tar.bz2 -C /tmp/
    EXTRACTED_DIR="/tmp/sherpa-onnx-${SHERPA_VERSION}-onnxruntime-${ONNXRUNTIME_VERSION}-osx-universal2-shared"
    cp "$EXTRACTED_DIR"/lib/libsherpa-onnx-c-api.dylib "$ROOT/Frameworks/lib/"
    cp "$EXTRACTED_DIR"/lib/libonnxruntime.${ONNXRUNTIME_VERSION}.dylib "$ROOT/Frameworks/lib/"
    cd "$ROOT/Frameworks/lib" && ln -sf "libonnxruntime.${ONNXRUNTIME_VERSION}.dylib" libonnxruntime.dylib && cd "$ROOT"
    # Copy C headers when the archive still ships them. Newer sherpa-onnx shared
    # tarballs dropped onnxruntime headers — keep vendored Sources/* headers.
    if [ -f "$EXTRACTED_DIR/include/sherpa-onnx/c-api/c-api.h" ]; then
        cp "$EXTRACTED_DIR/include/sherpa-onnx/c-api/c-api.h" "$ROOT/Sources/CSherpaOnnx/include/c-api.h"
    fi
    if [ -f "$EXTRACTED_DIR/include/onnxruntime/core/session/onnxruntime_c_api.h" ]; then
        cp "$EXTRACTED_DIR/include/onnxruntime/core/session/onnxruntime_c_api.h" \
            "$ROOT/Sources/COnnxRuntime/include/onnxruntime_c_api.h"
    fi
    if [ -f "$EXTRACTED_DIR/include/onnxruntime/core/session/onnxruntime_ep_c_api.h" ]; then
        cp "$EXTRACTED_DIR/include/onnxruntime/core/session/onnxruntime_ep_c_api.h" \
            "$ROOT/Sources/COnnxRuntime/include/onnxruntime_ep_c_api.h"
    fi
    rm -f /tmp/sherpa-onnx-shared.tar.bz2
    rm -rf "$EXTRACTED_DIR"
    echo "Libraries installed to Frameworks/lib/"
else
    echo "sherpa-onnx libraries already present."
fi

echo ""
echo "Libraries:"
ls -lh "$ROOT/Frameworks/lib/"

# --- Download Parakeet TDT model ---
if [ ! -d "$ROOT/models/${TDT_MODEL_NAME}" ]; then
    echo ""
    echo "Downloading Parakeet TDT 0.6b v3 (int8) model (~465MB compressed)..."
    mkdir -p "$ROOT/models"
    MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${TDT_MODEL_NAME}.tar.bz2"
    curl -L "$MODEL_URL" -o /tmp/parakeet-tdt-model.tar.bz2
    echo "Extracting model..."
    tar xjf /tmp/parakeet-tdt-model.tar.bz2 -C "$ROOT/models/"
    rm -f /tmp/parakeet-tdt-model.tar.bz2
    echo "TDT model installed to models/${TDT_MODEL_NAME}/"
else
    echo "Parakeet TDT model already present."
fi

# --- Download Silero VAD model ---
if [ ! -f "$ROOT/models/silero_vad.onnx" ]; then
    echo ""
    echo "Downloading Silero VAD model..."
    mkdir -p "$ROOT/models"
    curl -L "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx" \
        -o "$ROOT/models/silero_vad.onnx"
    echo "VAD model installed to models/silero_vad.onnx"
else
    echo "Silero VAD model already present."
fi

# --- Download Sparkle.framework ---
if [ ! -d "$ROOT/Frameworks/Sparkle.framework" ]; then
    echo ""
    echo "Downloading Sparkle.framework (2.8.1)..."
    SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz"
    curl -L "$SPARKLE_URL" -o /tmp/Sparkle-2.8.1.tar.xz
    echo "Extracting..."
    mkdir -p /tmp/sparkle-extract
    tar xf /tmp/Sparkle-2.8.1.tar.xz -C /tmp/sparkle-extract
    cp -R /tmp/sparkle-extract/Sparkle.framework "$ROOT/Frameworks/"
    rm -f /tmp/Sparkle-2.8.1.tar.xz
    rm -rf /tmp/sparkle-extract
    echo "Sparkle.framework installed to Frameworks/"
else
    echo "Sparkle.framework already present."
fi

echo ""
echo "Model files:"
ls -lh "$ROOT/models/${TDT_MODEL_NAME}/" 2>/dev/null || echo "  (not downloaded yet)"
echo ""
ls -lh "$ROOT/models/silero_vad.onnx" 2>/dev/null || echo "  (VAD model not downloaded yet)"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  swift build       # Build Chirp"
echo "  swift run Chirp   # Build and run"
