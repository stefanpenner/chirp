// swift-tools-version: 6.2
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Chirp",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Chirp", targets: ["Chirp"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Chirp",
            dependencies: [
                "CSherpaOnnx",
            ],
            path: "Sources/Chirp",
            exclude: ["Info.plist", "Chirp.entitlements", "Main.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
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
        .testTarget(
            name: "ChirpTests",
            dependencies: ["Chirp"],
            path: "Tests/ChirpTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            publicHeadersPath: "include"
        ),
    ]
)
