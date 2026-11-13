// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioDetection",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AudioDetection", targets: ["AudioDetection"]),
        .library(name: "KeywordSpotting", targets: ["KeywordSpotting"]),
        .executable(name: "DetectionProbe", targets: ["DetectionProbe"]),
        .library(name: "WhisperTranscription", targets: ["WhisperTranscription"]),
        .executable(name: "WhisperProbe", targets: ["WhisperProbe"]),
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
        .binaryTarget(name: "WhisperNative", path: "Vendor/WhisperNative.xcframework"),
        .target(name: "WhisperTranscription", dependencies: ["WhisperNative"],
                resources: [.copy("Models")],
                linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")]),
        .executableTarget(name: "WhisperProbe", dependencies: ["WhisperTranscription"]),
        .target(name: "AudioDetection", dependencies: ["OverlapRuntime"], resources: [.copy("Models")]),
        // Listens for muted words inside overlapping speech (~5 MB model). Linked into the app.
        .target(
            name: "KeywordSpotting",
            dependencies: ["AudioDetection", .product(name: "sherpa-onnx", package: "sherpa-onnx")],
            resources: [.copy("Models")]
        ),
        // Slow voice separation (~100 MB model). Probe and tests only; not in the app.
        .target(
            name: "WordDetection",
            dependencies: ["AudioDetection", "KeywordSpotting"],
            resources: [.copy("Models")]
        ),
        .executableTarget(name: "DetectionProbe", dependencies: ["AudioDetection", "KeywordSpotting", "WordDetection"]),
        .testTarget(name: "AudioDetectionTests", dependencies: ["AudioDetection", "KeywordSpotting", "WordDetection"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "WhisperTranscriptionTests", dependencies: ["WhisperTranscription"],
                    resources: [.copy("Fixtures")]),
    ]
)
