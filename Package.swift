// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Yodel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Yodel", targets: ["Yodel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "Yodel",
            dependencies: ["HotKey", "CSherpaOnnx"],
            path: "Sources/Yodel",
            exclude: ["Info.plist", "Yodel.entitlements"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
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
