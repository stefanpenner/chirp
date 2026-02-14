#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SHERPA_VERSION="v1.12.24"
ONNXRUNTIME_VERSION="1.23.2"
MODEL_NAME="sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"

echo "=== Yodel Setup ==="
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
    rm -f /tmp/sherpa-onnx-shared.tar.bz2
    rm -rf "$EXTRACTED_DIR"
    echo "Libraries installed to Frameworks/lib/"
else
    echo "sherpa-onnx libraries already present."
fi

echo ""
echo "Libraries:"
ls -lh "$ROOT/Frameworks/lib/"

# --- Download Parakeet model ---
if [ ! -d "$ROOT/models/${MODEL_NAME}" ]; then
    echo ""
    echo "Downloading Parakeet TDT 0.6b v2 (int8) model (~240MB compressed, ~630MB extracted)..."
    mkdir -p "$ROOT/models"
    MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"
    curl -L "$MODEL_URL" -o /tmp/parakeet-model.tar.bz2
    echo "Extracting model..."
    tar xjf /tmp/parakeet-model.tar.bz2 -C "$ROOT/models/"
    rm -f /tmp/parakeet-model.tar.bz2
    echo "Model installed to models/${MODEL_NAME}/"
else
    echo "Parakeet model already present."
fi

echo ""
echo "Model files:"
ls -lh "$ROOT/models/${MODEL_NAME}/" 2>/dev/null || echo "  (not downloaded yet)"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  swift build       # Build Yodel"
echo "  make run          # Build and run"
