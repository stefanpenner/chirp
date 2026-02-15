"""External dependency repository rules for Chirp.

Downloads prebuilt sherpa-onnx libraries, Sparkle.framework, and the
Silero VAD model so that `bazel build` works without running setup.sh.
The Parakeet TDT model is NOT included here — it is large (~631 MB) and
downloaded lazily at runtime by ModelManager on first launch.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")

_SHERPA_ONNX_VERSION = "v1.12.24"
_ONNXRUNTIME_VERSION = "1.23.2"
_SPARKLE_VERSION = "2.8.1"

def _deps_impl(module_ctx):
    http_archive(
        name = "sherpa_onnx",
        urls = [
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/{version}/sherpa-onnx-{version}-onnxruntime-{ort}-osx-universal2-shared.tar.bz2".format(
                version = _SHERPA_ONNX_VERSION,
                ort = _ONNXRUNTIME_VERSION,
            ),
        ],
        strip_prefix = "sherpa-onnx-{version}-onnxruntime-{ort}-osx-universal2-shared".format(
            version = _SHERPA_ONNX_VERSION,
            ort = _ONNXRUNTIME_VERSION,
        ),
        # TODO: pin sha256 for reproducibility (omit to let Bazel print it on first fetch)
        build_file_content = """
load("@rules_cc//cc:cc_import.bzl", "cc_import")

cc_import(
    name = "sherpaonnx",
    shared_library = "lib/libsherpa-onnx-c-api.dylib",
    visibility = ["//visibility:public"],
)

cc_import(
    name = "onnxruntime",
    shared_library = "lib/libonnxruntime.{ort}.dylib",
    visibility = ["//visibility:public"],
)
""".format(ort = _ONNXRUNTIME_VERSION),
    )

    http_archive(
        name = "sparkle",
        urls = [
            "https://github.com/sparkle-project/Sparkle/releases/download/{version}/Sparkle-{version}.tar.xz".format(
                version = _SPARKLE_VERSION,
            ),
        ],
        # TODO: pin sha256
        build_file_content = """
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import")

apple_dynamic_framework_import(
    name = "Sparkle",
    framework_imports = glob(["Sparkle.framework/**"]),
    visibility = ["//visibility:public"],
)
""",
    )

    http_file(
        name = "silero_vad",
        urls = [
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
        ],
        downloaded_file_path = "silero_vad.onnx",
        # TODO: pin sha256
    )

    return module_ctx.extension_metadata(
        root_module_direct_deps = ["sherpa_onnx", "sparkle", "silero_vad"],
        root_module_direct_dev_deps = [],
    )

deps = module_extension(implementation = _deps_impl)
