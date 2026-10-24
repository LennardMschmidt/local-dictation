// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalDictation", targets: ["LocalDictation"]),
        .executable(name: "dictate", targets: ["dictate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .target(name: "DictationCore"),
        .target(
            name: "DictationASR",
            dependencies: [
                "DictationCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(name: "dictate", dependencies: ["DictationCore", "DictationASR"]),
        .executableTarget(name: "LocalDictation", dependencies: ["DictationCore", "DictationASR"]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
    ],
    swiftLanguageModes: [.v5]
)
