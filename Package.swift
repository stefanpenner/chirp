// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Chirp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Chirp", targets: ["Chirp"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Chirp",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/Chirp",
            exclude: ["Info.plist", "Chirp.entitlements"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .unsafeFlags([
                    "-L\(packageDir)/Frameworks/lib",
                    "-lsherpa-onnx-c-api",
                    "-lonnxruntime",
                    "-Xlinker", "-rpath", "-Xlinker", "\(packageDir)/Frameworks/lib",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            publicHeadersPath: "include"
        ),
    ]
)
