// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioDetection",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AudioDetection", targets: ["AudioDetection"]),
        .library(name: "KeywordSpotting", targets: ["KeywordSpotting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "2.0.1"),
        .package(url: "https://github.com/csukuangfj/onnxruntime-libs", exact: "1.28.2"),
    ],
    targets: [
        .target(name: "OverlapRuntime", dependencies: [
            .product(name: "onnxruntime-macos", package: "onnxruntime-libs", condition: .when(platforms: [.macOS])),
            .product(name: "onnxruntime-ios", package: "onnxruntime-libs", condition: .when(platforms: [.iOS]))
        ], linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Foundation"), .linkedFramework("CoreML")]),
        .target(name: "AudioDetection", dependencies: ["OverlapRuntime"], resources: [.copy("Models")]),
        // Listens for muted words inside overlapping speech (~5 MB model). Linked into the app.
        .target(
            name: "KeywordSpotting",
            dependencies: ["AudioDetection", .product(name: "sherpa-onnx", package: "sherpa-onnx")],
            resources: [.copy("Models")]
        ),
        .testTarget(name: "AudioDetectionTests", dependencies: ["AudioDetection", "KeywordSpotting"],
                    resources: [.copy("Fixtures")]),
    ]
)
