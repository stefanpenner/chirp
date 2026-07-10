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
        sha256 = "12bb5965c63946f2514dfbd3e2b8f0ee21ad28d46f38a4db4f2180677aed04ad",
        build_file_content = """
load("@rules_cc//cc:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_swift//swift:swift.bzl", "swift_interop_hint")

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

swift_interop_hint(
    name = "CSherpaOnnx_interop",
    module_name = "CSherpaOnnx",
)

cc_library(
    name = "CSherpaOnnx",
    hdrs = ["include/sherpa-onnx/c-api/c-api.h"],
    strip_include_prefix = "include/sherpa-onnx/c-api",
    deps = [":sherpaonnx", ":onnxruntime"],
    aspect_hints = [":CSherpaOnnx_interop"],
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
        sha256 = "5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be",
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
        integrity = "sha256-niRJ4Qh0ltjUyrqQfyPgvT942R+lUkebucI6wJy7H9Y=",
    )

    return module_ctx.extension_metadata(
        root_module_direct_deps = ["sherpa_onnx", "sparkle", "silero_vad"],
        root_module_direct_dev_deps = [],
    )

deps = module_extension(implementation = _deps_impl)
