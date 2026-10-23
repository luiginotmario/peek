// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Peek", targets: ["Peek"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
    ],
    targets: [
        // the engine: photos library, siglip encoders and the on-disk index. no ui, nonisolated.
        .target(
            name: "PeekCore",
            dependencies: [.product(name: "Tokenizers", package: "swift-transformers")]
        ),
        .testTarget(name: "PeekCoreTests", dependencies: ["PeekCore"]),
        // the menu bar app
        .executableTarget(
            name: "Peek",
            dependencies: ["PeekCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
